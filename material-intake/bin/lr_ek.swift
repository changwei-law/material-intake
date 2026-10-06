// 来福 · EventKit 后端（macOS 日历 + 提醒事项）
//
// 用法：echo '<JSON请求>' | lr_ek
// 输出：统一 JSON 到 stdout；失败时 {"ok":false,"error":"..."} 并返回码 1。
//
// 约束与设计说明：
// 1. 条目识别靠「锚点」——写入时在备注末行写入 "来福ID: <anchor>"，
//    读取/更新/删除均按该行精确匹配（整行相等），不使用模糊包含，避免误伤同名条目。
// 2. 周周期事件用 EventKit 原生 recurrenceRule 建立（真周期，长期自动重复）。
//    macOS 的 AppleScript 通道无法删除周期事件（实测静默失败），EventKit 可以。
// 3. 所有输出日期均为本地时区的 "yyyy-MM-dd'T'HH:mm:ss"。

import Foundation
import EventKit

// MARK: - 通用工具

func emit(_ obj: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print("{\"ok\":false,\"error\":\"json encode failed\"}")
    }
}

func die(_ msg: String) -> Never {
    emit(["ok": false, "error": msg])
    exit(1)
}

let localTZ = TimeZone.current

func makeFormatter(_ pattern: String) -> DateFormatter {
    let f = DateFormatter()
    f.dateFormat = pattern
    f.timeZone = localTZ
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}

let fullFormatter = makeFormatter("yyyy-MM-dd'T'HH:mm:ss")
let minuteFormatter = makeFormatter("yyyy-MM-dd'T'HH:mm")
let dateFormatter = makeFormatter("yyyy-MM-dd")

func parseDate(_ value: Any?) -> Date? {
    guard let s = value as? String, !s.isEmpty else { return nil }
    if let d = fullFormatter.date(from: s) { return d }
    if let d = minuteFormatter.date(from: s) { return d }
    if let d = dateFormatter.date(from: s) { return d }
    return nil
}

func fmt(_ d: Date?) -> String {
    guard let d = d else { return "" }
    return fullFormatter.string(from: d)
}

func anchorLine(_ anchor: String) -> String { "来福ID: " + anchor }

func hasAnchor(_ notes: String?, _ anchor: String) -> Bool {
    guard let notes = notes, !notes.isEmpty else { return false }
    let target = anchorLine(anchor)
    for raw in notes.split(separator: "\n", omittingEmptySubsequences: false) {
        if raw.trimmingCharacters(in: .whitespaces) == target { return true }
    }
    return false
}

/// 支持按精确锚点或锚点前缀匹配（前缀用于批量清理同一周期事项的历史条目）。
func matchesAnchor(_ notes: String?, exact: String?, prefix: String?) -> Bool {
    guard let notes = notes, !notes.isEmpty else { return false }
    if let exact = exact, !exact.isEmpty {
        return hasAnchor(notes, exact)
    }
    if let prefix = prefix, !prefix.isEmpty {
        let target = anchorLine(prefix)
        for raw in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix(target) { return true }
        }
    }
    return false
}

func requestAnchor(_ req: [String: Any]) -> (exact: String?, prefix: String?) {
    let exact = req["anchor"] as? String
    let prefix = req["anchor_prefix"] as? String
    return (exact?.isEmpty == true ? nil : exact, prefix?.isEmpty == true ? nil : prefix)
}

func composeNotes(_ body: String?, _ anchor: String) -> String {
    var lines: [String] = []
    if let body = body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        lines.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    lines.append(anchorLine(anchor))
    return lines.joined(separator: "\n")
}

// MARK: - 请求解析

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard let rawReq = try? JSONSerialization.jsonObject(with: stdinData),
      let req = rawReq as? [String: Any] else {
    die("无法解析 stdin 上的 JSON 请求")
}

let cmd = (req["cmd"] as? String) ?? ""
let store = EKEventStore()

// MARK: - 授权

func requestEvents() -> Bool {
    if #available(macOS 14.0, *) {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return true }
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
        _ = sem.wait(timeout: .now() + 30)
        return granted
    } else {
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        store.requestAccess(to: .event) { ok, _ in granted = ok; sem.signal() }
        _ = sem.wait(timeout: .now() + 30)
        return granted
    }
}

func requestReminders() -> Bool {
    if #available(macOS 14.0, *) {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess { return true }
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        store.requestFullAccessToReminders { ok, _ in granted = ok; sem.signal() }
        _ = sem.wait(timeout: .now() + 30)
        return granted
    } else {
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        store.requestAccess(to: .reminder) { ok, _ in granted = ok; sem.signal() }
        _ = sem.wait(timeout: .now() + 30)
        return granted
    }
}

func authStatusText(_ entity: EKEntityType) -> String {
    let s = EKEventStore.authorizationStatus(for: entity)
    switch s {
    case .notDetermined: return "未授权"
    case .restricted: return "受限"
    case .denied: return "已拒绝"
    case .authorized: return "已授权"
    case .fullAccess: return "完全访问"
    case .writeOnly: return "仅写入"
    @unknown default: return "未知"
    }
}

// MARK: - 查找辅助

func findCalendar(_ title: String) -> EKCalendar? {
    let all = store.calendars(for: .event)
    return all.first { $0.title == title && $0.allowsContentModifications }
        ?? all.first { $0.title == title }
}

func findReminderList(_ title: String) -> EKCalendar? {
    let all = store.calendars(for: .reminder)
    return all.first { $0.title == title && $0.allowsContentModifications }
        ?? all.first { $0.title == title }
}

func eventSeriesId(_ event: EKEvent) -> String {
    // 注意：本机实测 EKEvent.eventIdentifier 形如「<日历UUID>:<事件UUID>」，按 ":" 截断会把
    // 同一日历内的所有事件误当成同一周期系列，导致 list_events 只返回第一条（2026-09-27 复现并修正）。
    // 周期事件的所有实例共享同一 eventIdentifier，直接用完整标识去重即可。
    guard let id = event.eventIdentifier else { return UUID().uuidString }
    return id
}

/// 按锚点查找事件。返回按序列去重后的代表事件（周期事件取最早一次）。
func findEvents(calendar: EKCalendar, exact: String?, prefix: String?, from: Date, to: Date) -> [EKEvent] {
    let pred = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
    let matches = store.events(matching: pred).filter { matchesAnchor($0.notes, exact: exact, prefix: prefix) }
    var seen = Set<String>()
    var result: [EKEvent] = []
    for e in matches.sorted(by: { $0.startDate < $1.startDate }) {
        let key = eventSeriesId(e)
        if seen.contains(key) { continue }
        seen.insert(key)
        result.append(e)
    }
    return result
}

func fetchReminders(list: EKCalendar) -> [EKReminder] {
    let pred = store.predicateForReminders(in: [list])
    let sem = DispatchSemaphore(value: 0)
    var result: [EKReminder] = []
    store.fetchReminders(matching: pred) { rems in
        result = rems ?? []
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 30)
    return result
}

func recurrenceRule(from dict: [String: Any]?) -> EKRecurrenceRule? {
    guard let d = dict, let freqText = d["freq"] as? String else { return nil }
    let frequency: EKRecurrenceFrequency
    switch freqText.uppercased() {
    case "DAILY": frequency = .daily
    case "WEEKLY": frequency = .weekly
    case "MONTHLY": frequency = .monthly
    case "YEARLY": frequency = .yearly
    default: return nil
    }
    let interval = (d["interval"] as? Int) ?? 1

    var daysOfWeek: [EKRecurrenceDayOfWeek] = []
    if let weekdays = d["byweekdays"] as? [String] {
        for wd in weekdays {
            if let day = weekday(from: wd) {
                daysOfWeek.append(EKRecurrenceDayOfWeek(dayOfTheWeek: day, weekNumber: 0))
            }
        }
    }
    if let ordinal = d["byday_ordinal"] as? Int, let wd = d["byday_weekday"] as? String, let day = weekday(from: wd) {
        daysOfWeek.append(EKRecurrenceDayOfWeek(dayOfTheWeek: day, weekNumber: ordinal))
    }
    var daysOfMonth: [NSNumber] = []
    if let dom = d["bymonthday"] as? Int { daysOfMonth.append(NSNumber(value: dom)) }

    return EKRecurrenceRule(
        recurrenceWith: frequency,
        interval: interval,
        daysOfTheWeek: daysOfWeek.isEmpty ? nil : daysOfWeek,
        daysOfTheMonth: daysOfMonth.isEmpty ? nil : daysOfMonth,
        monthsOfTheYear: nil,
        weeksOfTheYear: nil,
        daysOfTheYear: nil,
        setPositions: nil,
        end: nil
    )
}

func weekday(from text: String) -> EKWeekday? {
    switch text.uppercased() {
    case "SU", "SUN": return .sunday
    case "MO", "MON": return .monday
    case "TU", "TUE": return .tuesday
    case "WE", "WED": return .wednesday
    case "TH", "THU": return .thursday
    case "FR", "FRI": return .friday
    case "SA", "SAT": return .saturday
    default: return nil
    }
}

/// 把周期规则归一化成字符串，用于「内容是否变化」的比较。
func ruleSignature(_ rule: EKRecurrenceRule?) -> String {
    guard let rule = rule else { return "" }
    var parts: [String] = ["FREQ=\(rule.frequency.rawValue)", "INTERVAL=\(rule.interval)"]
    if let days = rule.daysOfTheWeek {
        let text = days.map { "\($0.weekNumber)\($0.dayOfTheWeek.rawValue)" }.sorted().joined(separator: ",")
        parts.append("BYDAY=\(text)")
    }
    if let doms = rule.daysOfTheMonth {
        parts.append("BYMONTHDAY=\(doms.map { $0.stringValue }.sorted().joined(separator: ","))")
    }
    return parts.joined(separator: ";")
}

func signature(of event: EKEvent) -> String {
    let rule = (event.recurrenceRules?.first)
    return [
        event.title ?? "",
        event.location ?? "",
        event.notes ?? "",
        event.isAllDay ? "1" : "0",
        fmt(event.startDate),
        fmt(event.endDate),
        ruleSignature(rule),
    ].joined(separator: "\u{1f}")
}

func eventPayload(_ e: EKEvent) -> [String: Any] {
    return [
        "id": e.eventIdentifier ?? "",
        "series_id": eventSeriesId(e),
        "title": e.title ?? "",
        "start": fmt(e.startDate),
        "end": fmt(e.endDate),
        "location": e.location ?? "",
        "notes": e.notes ?? "",
        "all_day": e.isAllDay,
        "recurring": e.hasRecurrenceRules,
        "calendar": e.calendar?.title ?? "",
    ]
}

func reminderPayload(_ r: EKReminder) -> [String: Any] {
    var due = ""
    if let comps = r.dueDateComponents {
        if let d = Calendar.current.date(from: comps) { due = fmt(d) }
    }
    return [
        "id": r.calendarItemIdentifier,
        "title": r.title ?? "",
        "notes": r.notes ?? "",
        "due": due,
        "completed": r.isCompleted,
        "list": r.calendar?.title ?? "",
    ]
}

// MARK: - 命令实现

func run(_ req: [String: Any]) -> [String: Any] {
    switch cmd {
    case "doctor":
        let evOK = requestEvents()
        let remOK = requestReminders()
        return [
            "ok": true,
            "events_auth": authStatusText(.event),
            "reminders_auth": authStatusText(.reminder),
            "events_accessible": evOK,
            "reminders_accessible": remOK,
            "calendars": store.calendars(for: .event).map { $0.title },
            "reminder_lists": store.calendars(for: .reminder).map { $0.title },
        ]

    case "list_calendars":
        _ = requestEvents()
        return ["ok": true, "calendars": store.calendars(for: .event).map { $0.title }]

    case "ensure_calendar":
        // 确保指定名称的日历存在（不存在则新建），用于「破产案件期限」这类专用日历
        guard requestEvents() else { return ["ok": false, "error": "无日历访问权限"] }
        let wanted = ((req["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return ["ok": false, "error": "title 缺失"] }
        if let existing = findCalendar(wanted) {
            return ["ok": true, "action": "exists", "calendar": existing.title,
                    "source": existing.source?.title ?? ""]
        }
        // 优先建在「本机」账户：iCloud 新建日历在同步完成前写入会被回滚（实测：首次写入成功、后续写入丢失），
        // 本机日历不参与 iCloud 同步，写入稳定。可用 req["source"] 显式指定账户类型（local／icloud）。
        let sourcePreference = (req["source"] as? String)?.lowercased() ?? "local"
        let localSource = store.sources.first { $0.sourceType == .local }
        let chosenSource: EKSource?
        switch sourcePreference {
        case "icloud": chosenSource = store.defaultCalendarForNewEvents?.source
        case "any": chosenSource = localSource ?? store.defaultCalendarForNewEvents?.source
        default: chosenSource = localSource ?? store.defaultCalendarForNewEvents?.source
        }
        guard let source = chosenSource else {
            return ["ok": false, "error": "无法定位可写日历账户；请先在「日历」中保留一个可写日历"]
        }
        let created = EKCalendar(for: .event, eventStore: store)
        created.title = wanted
        created.source = source
        do {
            try store.saveCalendar(created, commit: true)
            return ["ok": true, "action": "created", "calendar": created.title,
                    "source": source.title]
        } catch {
            return ["ok": false, "error": "创建日历失败：\(error.localizedDescription)"]
        }

    case "ensure_list":
        // 确保指定名称的提醒清单存在（不存在则新建），用于「破产案件期限」这类专用清单
        guard requestReminders() else { return ["ok": false, "error": "无提醒事项访问权限"] }
        let wantedList = ((req["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !wantedList.isEmpty else { return ["ok": false, "error": "title 缺失"] }
        if let existing = findReminderList(wantedList) {
            return ["ok": true, "action": "exists", "list": existing.title]
        }
        guard let reminderSource = store.defaultCalendarForNewReminders()?.source else {
            return ["ok": false, "error": "无法定位可写提醒账户；请先在「提醒事项」中保留一个可写清单"]
        }
        let createdList = EKCalendar(for: .reminder, eventStore: store)
        createdList.title = wantedList
        createdList.source = reminderSource
        do {
            try store.saveCalendar(createdList, commit: true)
            return ["ok": true, "action": "created", "list": createdList.title,
                    "source": reminderSource.title]
        } catch {
            return ["ok": false, "error": "创建提醒清单失败：\(error.localizedDescription)"]
        }

    case "delete_calendar":
        // 删除指定名称的日历（仅用于清理创建后异常、需要重建的自建日历）
        guard requestEvents() else { return ["ok": false, "error": "无日历访问权限"] }
        let victim = ((req["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !victim.isEmpty else { return ["ok": false, "error": "title 缺失"] }
        guard let target = findCalendar(victim) else {
            return ["ok": false, "error": "找不到日历：\(victim)"]
        }
        do {
            try store.removeCalendar(target, commit: true)
            return ["ok": true, "action": "deleted", "calendar": victim]
        } catch {
            return ["ok": false, "error": "删除日历失败：\(error.localizedDescription)"]
        }

    case "list_reminder_lists":
        _ = requestReminders()
        return ["ok": true, "reminder_lists": store.calendars(for: .reminder).map { $0.title }]

    case "list_events":
        guard requestEvents() else { return ["ok": false, "error": "无日历访问权限"] }
        guard let from = parseDate(req["from"]), let to = parseDate(req["to"]) else {
            return ["ok": false, "error": "from/to 参数缺失或格式错误"]
        }
        // calendar 省略时跨全部日历查询（诊断用）
        let calTitle = req["calendar"] as? String
        var calendars: [EKCalendar]? = nil
        if let title = calTitle, !title.isEmpty {
            guard let cal = findCalendar(title) else {
                return ["ok": false, "error": "找不到日历：\(title)"]
            }
            calendars = [cal]
        }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        let raw = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        var seen = Set<String>()
        var items: [[String: Any]] = []
        for e in raw {
            let key = eventSeriesId(e)
            if seen.contains(key) { continue }
            seen.insert(key)
            items.append(eventPayload(e))
        }
        return ["ok": true, "events": items]

    case "upsert_event":
        guard requestEvents() else { return ["ok": false, "error": "无日历访问权限"] }
        guard let calTitle = req["calendar"] as? String, let cal = findCalendar(calTitle) else {
            return ["ok": false, "error": "找不到日历：\((req["calendar"] as? String) ?? "")"]
        }
        guard let anchor = req["anchor"] as? String, !anchor.isEmpty else {
            return ["ok": false, "error": "anchor 缺失"]
        }
        guard let start = parseDate(req["start"]) else {
            return ["ok": false, "error": "start 缺失或格式错误"]
        }
        let allDay = (req["all_day"] as? Bool) ?? false
        var end = parseDate(req["end"]) ?? start.addingTimeInterval(7200)
        if end <= start { end = start.addingTimeInterval(7200) }

        let searchFrom = min(start, Date()).addingTimeInterval(-3600 * 24 * 370)
        let searchTo = max(start, Date()).addingTimeInterval(3600 * 24 * 1100)
        let existing = findEvents(calendar: cal, exact: anchor, prefix: nil, from: searchFrom, to: searchTo)

        let body = req["notes"] as? String
        let notes = composeNotes(body, anchor)
        let title = (req["title"] as? String) ?? "(无标题)"
        let location = (req["location"] as? String) ?? ""
        let rule = recurrenceRule(from: req["recurrence"] as? [String: Any])

        if let event = existing.first {
            let desiredSignature = [
                title,
                location,
                notes,
                allDay ? "1" : "0",
                fmt(start),
                fmt(end),
                ruleSignature(rule),
            ].joined(separator: "\u{1f}")
            if signature(of: event) == desiredSignature {
                return ["ok": true, "action": "unchanged", "id": event.eventIdentifier ?? ""]
            }
            // 更新路径：先放开结束时间，避免「开始日期必须早于结束日期」报错。
            if event.hasRecurrenceRules && rule == nil {
                // 从周期降级为单次：删除原序列，改为新建。
                do { try store.remove(event, span: .futureEvents) } catch {
                    return ["ok": false, "error": "降级周期事件失败：\(error.localizedDescription)"]
                }
            } else {
                event.title = title
                event.location = location
                event.notes = notes
                event.isAllDay = allDay
                if event.hasRecurrenceRules {
                    do { try store.remove(event, span: .futureEvents) } catch {
                        return ["ok": false, "error": "重建周期事件失败：\(error.localizedDescription)"]
                    }
                } else {
                    event.endDate = max(end, start.addingTimeInterval(3600))
                    event.startDate = start
                    event.endDate = end
                    if let rule = rule { event.recurrenceRules = [rule] }
                    do {
                        try store.save(event, span: .thisEvent, commit: true)
                        return ["ok": true, "action": "updated", "id": event.eventIdentifier ?? ""]
                    } catch {
                        return ["ok": false, "error": "保存失败：\(error.localizedDescription)"]
                    }
                }
            }
        }

        let event = EKEvent(eventStore: store)
        event.calendar = cal
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        event.location = location
        event.notes = notes
        if let rule = rule { event.recurrenceRules = [rule] }
        do {
            try store.save(event, span: .thisEvent, commit: true)
            var payload: [String: Any] = ["ok": true, "action": existing.isEmpty ? "created" : "recreated",
                                          "id": event.eventIdentifier ?? ""]
            payload["title"] = title
            payload["start"] = fmt(start)
            return payload
        } catch {
            return ["ok": false, "error": "写入失败：\(error.localizedDescription)"]
        }

    case "upsert_events":
        // 批量写入（单进程、末尾一次 commit）：实测本机 EventKit 在「多个短生命周期进程连续写入」时
        // 只有第一条能落盘（2026-09-27 复现），改为进程内循环 + 统一提交，保证整批写入原子生效。
        guard requestEvents() else { return ["ok": false, "error": "无日历访问权限"] }
        guard let specs = req["items"] as? [[String: Any]], !specs.isEmpty else {
            return ["ok": false, "error": "items 缺失"]
        }
        let batchTitle = (req["calendar"] as? String) ?? ""
        guard let batchCal = findCalendar(batchTitle) else {
            return ["ok": false, "error": "找不到日历：\(batchTitle)"]
        }
        var results: [[String: Any]] = []
        var dirty = false
        for spec in specs {
            let anchor = (spec["anchor"] as? String) ?? ""
            guard !anchor.isEmpty, let start = parseDate(spec["start"]) else {
                results.append(["ok": false, "anchor": anchor, "error": "anchor/start 缺失"])
                continue
            }
            let title = (spec["title"] as? String) ?? "(无标题)"
            let notes = composeNotes(spec["notes"] as? String, anchor)
            let location = (spec["location"] as? String) ?? ""
            let allDay = (spec["all_day"] as? Bool) ?? false
            var end = parseDate(spec["end"]) ?? start.addingTimeInterval(1800)
            if end <= start { end = start.addingTimeInterval(1800) }
            let searchFrom = min(start, Date()).addingTimeInterval(-3600 * 24 * 370)
            let searchTo = max(start, Date()).addingTimeInterval(3600 * 24 * 1100)
            let existing = findEvents(calendar: batchCal, exact: anchor, prefix: nil,
                                      from: searchFrom, to: searchTo)
            if let event = existing.first {
                let desired = [title, location, notes, allDay ? "1" : "0", fmt(start), fmt(end)]
                    .joined(separator: "\u{1f}")
                if signature(of: event) == desired {
                    results.append(["ok": true, "anchor": anchor, "action": "unchanged"])
                    continue
                }
                event.title = title
                event.location = location
                event.notes = notes
                event.isAllDay = allDay
                event.startDate = start
                event.endDate = end
                do {
                    try store.save(event, span: .thisEvent, commit: false)
                    dirty = true
                    results.append(["ok": true, "anchor": anchor, "action": "updated"])
                } catch {
                    results.append(["ok": false, "anchor": anchor,
                                    "error": "保存失败：\(error.localizedDescription)"])
                }
                continue
            }
            let event = EKEvent(eventStore: store)
            event.calendar = batchCal
            event.title = title
            event.startDate = start
            event.endDate = end
            event.isAllDay = allDay
            event.location = location
            event.notes = notes
            do {
                try store.save(event, span: .thisEvent, commit: false)
                dirty = true
                results.append(["ok": true, "anchor": anchor, "action": "created"])
            } catch {
                results.append(["ok": false, "anchor": anchor,
                                "error": "写入失败：\(error.localizedDescription)"])
            }
        }
        if dirty {
            do { try store.commit() } catch {
                return ["ok": false, "error": "批量提交失败：\(error.localizedDescription)",
                        "items": results]
            }
        }
        return ["ok": true, "count": results.count, "items": results]

    case "delete_events":
        guard requestEvents() else { return ["ok": false, "error": "无日历访问权限"] }
        guard let calTitle = req["calendar"] as? String, let cal = findCalendar(calTitle) else {
            return ["ok": false, "error": "找不到日历：\((req["calendar"] as? String) ?? "")"]
        }
        let (exact, prefix) = requestAnchor(req)
        guard exact != nil || prefix != nil else { return ["ok": false, "error": "anchor 缺失"] }
        let from = parseDate(req["from"]) ?? Date().addingTimeInterval(-3600 * 24 * 370)
        let to = parseDate(req["to"]) ?? Date().addingTimeInterval(3600 * 24 * 1100)
        let targets = findEvents(calendar: cal, exact: exact, prefix: prefix, from: from, to: to)
        var deleted = 0
        var errors: [String] = []
        for e in targets {
            do {
                try store.remove(e, span: e.hasRecurrenceRules ? .futureEvents : .thisEvent, commit: true)
                deleted += 1
            } catch {
                errors.append("\(e.title ?? "")：\(error.localizedDescription)")
            }
        }
        return ["ok": errors.isEmpty, "deleted": deleted, "errors": errors]

    case "list_reminders":
        guard requestReminders() else { return ["ok": false, "error": "无提醒事项访问权限"] }
        guard let listTitle = req["list"] as? String, let list = findReminderList(listTitle) else {
            return ["ok": false, "error": "找不到提醒清单：\((req["list"] as? String) ?? "")"]
        }
        let includeCompleted = (req["include_completed"] as? Bool) ?? false
        let items = fetchReminders(list: list)
            .filter { includeCompleted || !$0.isCompleted }
            .map { reminderPayload($0) }
        return ["ok": true, "reminders": items]

    case "upsert_reminder":
        guard requestReminders() else { return ["ok": false, "error": "无提醒事项访问权限"] }
        guard let listTitle = req["list"] as? String, let list = findReminderList(listTitle) else {
            return ["ok": false, "error": "找不到提醒清单：\((req["list"] as? String) ?? "")"]
        }
        guard let anchor = req["anchor"] as? String, !anchor.isEmpty else {
            return ["ok": false, "error": "anchor 缺失"]
        }
        // due 允许缺省：无具体时点的推进型待办只建「无到期日」提醒，避免变成逾期噪音。
        let due = parseDate(req["due"])
        let title = (req["title"] as? String) ?? "(无标题)"
        let notes = composeNotes(req["notes"] as? String, anchor)

        let existing = fetchReminders(list: list).first { hasAnchor($0.notes, anchor) }
        let reminder = existing ?? EKReminder(eventStore: store)
        if existing == nil { reminder.calendar = list }
        if let existing = existing, existing.isCompleted == false {
            let sameDue: Bool
            let sameAlarm: Bool
            if let due = due {
                sameDue = existing.dueDateComponents
                    .flatMap { Calendar.current.date(from: $0) }
                    .map { abs($0.timeIntervalSince(due)) < 60 } ?? false
                sameAlarm = (existing.alarms?.count ?? 0) == 1
                    && abs((existing.alarms?.first?.absoluteDate ?? .distantPast).timeIntervalSince(due)) < 60
            } else {
                sameDue = existing.dueDateComponents == nil
                sameAlarm = (existing.alarms?.isEmpty ?? true)
            }
            if existing.title == title && existing.notes == notes && sameDue && sameAlarm {
                return ["ok": true, "action": "unchanged", "id": existing.calendarItemIdentifier]
            }
        }
        reminder.title = title
        reminder.notes = notes
        if let due = due {
            var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            comps.timeZone = localTZ
            reminder.dueDateComponents = comps
            reminder.alarms = [EKAlarm(absoluteDate: due)]
        } else {
            reminder.dueDateComponents = nil
            reminder.alarms = nil
        }
        do {
            try store.save(reminder, commit: true)
            return ["ok": true, "action": existing == nil ? "created" : "updated",
                    "id": reminder.calendarItemIdentifier]
        } catch {
            return ["ok": false, "error": "写入失败：\(error.localizedDescription)"]
        }

    case "delete_reminders":
        guard requestReminders() else { return ["ok": false, "error": "无提醒事项访问权限"] }
        guard let listTitle = req["list"] as? String, let list = findReminderList(listTitle) else {
            return ["ok": false, "error": "找不到提醒清单：\((req["list"] as? String) ?? "")"]
        }
        let (exact, prefix) = requestAnchor(req)
        guard exact != nil || prefix != nil else { return ["ok": false, "error": "anchor 缺失"] }
        let targets = fetchReminders(list: list).filter { matchesAnchor($0.notes, exact: exact, prefix: prefix) }
        var deleted = 0
        var errors: [String] = []
        for r in targets {
            do {
                try store.remove(r, commit: true)
                deleted += 1
            } catch {
                errors.append("\(r.title ?? "")：\(error.localizedDescription)")
            }
        }
        return ["ok": errors.isEmpty, "deleted": deleted, "errors": errors]

    default:
        return ["ok": false, "error": "未知命令：\(cmd)"]
    }
}

// MARK: - 入口（后台线程执行，主线程保持 run loop 以接收 EventKit 回调）

DispatchQueue.global().async {
    let result = run(req)
    emit(result)
    exit((result["ok"] as? Bool) == true ? 0 : 1)
}

dispatchMain()
