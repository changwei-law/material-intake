#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""材料代办录入 · 日程写入（macOS 直写日历与提醒；其他系统导出 .ics）

与 schedule-sync 技能使用同一套约定，两边的条目互相可识别、可清理：
1. 只操作带锚点「来福ID: <anchor>」的条目，绝不触碰手工创建的事件与提醒。
2. 写入前按锚点查找，命中即更新（upsert），不产生重复条目。
3. 缺省只预演（plan），加 --apply 才真正写入。
4. 非 macOS 平台不写日历：改为导出标准 .ics（含提醒），交 Windows
   日历、手机日历或桌面日历客户端导入。

子命令：
  doctor   平台、后端、授权与容器自检
  plan     校验清单并打印将要写入的内容（不写）
  apply    写入日历与提醒（macOS）；非 macOS 时改为导出 ICS
  ics      仅导出 .ics
  list     列出本工具写入的条目
  rm       按锚点撤销条目及其全部提醒档位

仅使用 Python 标准库。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

SKILL_DIR = Path(__file__).resolve().parent.parent
EK_SRC = SKILL_DIR / "bin" / "lr_ek.swift"
EK_BIN = SKILL_DIR / "bin" / "lr_ek"

DEFAULT_CALENDAR = "工作"
DEFAULT_REMINDER_LIST = "提醒"
DEFAULT_ANCHOR_PREFIX = "LR-MI-"

KIND_LABEL = {
    "hearing": "开庭",
    "deadline": "期限",
    "meeting": "会议",
    "task": "待办",
    "onsite": "驻场",
}

# 默认提醒节奏：开庭与期限四级；会议到期前一日与当天；一般待办只当天提醒。
DEFAULT_OFFSETS = {
    "hearing": [7, 3, 1, 0],
    "deadline": [7, 3, 1, 0],
    "onsite": [7, 3, 1, 0],
    "meeting": [1, 0],
    "task": [0],
}
REMIND_TIME_EARLY = time(9, 0)     # T-7 / T-3 / T-1
REMIND_TIME_SAMEDAY = time(7, 30)  # 当天


class ScheduleError(Exception):
    pass


# --------------------------------------------------------------------------
# 后端调用
# --------------------------------------------------------------------------


def is_macos() -> bool:
    return sys.platform == "darwin"


def ensure_binary() -> None:
    """后端缺失或源码更新时自动重编译（需要 Xcode 命令行工具里的 swiftc）。"""
    need_build = not EK_BIN.exists()
    if not need_build and EK_SRC.exists():
        need_build = EK_SRC.stat().st_mtime > EK_BIN.stat().st_mtime
    if not need_build:
        # 压缩包解压后可能丢失执行位，这里补一次，避免收件人拿到包就跑不起来。
        try:
            EK_BIN.chmod(EK_BIN.stat().st_mode | 0o755)
            probe = subprocess.run([str(EK_BIN)], input=b"{}", stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError:
            need_build = True
        else:
            if probe.returncode != 0 or b"Unknown command" not in probe.stdout + probe.stderr:
                need_build = True
    if not need_build:
        return
    if EK_BIN.exists() and not EK_SRC.exists():
        # 二进制在、源码不在：只要执行位补上就能跑，不必重编译
        EK_BIN.chmod(EK_BIN.stat().st_mode | 0o755)
        return
    if not is_macos():
        raise ScheduleError("非 macOS 平台没有 EventKit 后端，请改用 ics 子命令导出日历文件")
    if not EK_SRC.exists():
        raise ScheduleError("缺少后端源码 %s，无法编译。请从原包取回 bin/lr_ek 与 bin/lr_ek.swift" % EK_SRC)
    machine = subprocess.run(["uname", "-m"], capture_output=True, text=True).stdout.strip() or "arm64"
    cmd = ["swiftc", "-O", "-target", "%s-apple-macos14.0" % machine, str(EK_SRC), "-o", str(EK_BIN)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise ScheduleError(
            "编译 EventKit 后端失败（需要 Xcode 命令行工具：xcode-select --install）：\n%s" % proc.stderr[-1200:]
        )
    EK_BIN.chmod(0o755)


def call_ek(payload: dict) -> dict:
    ensure_binary()
    proc = subprocess.run(
        [str(EK_BIN)],
        input=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    out = proc.stdout.decode("utf-8", "replace").strip()
    if not out:
        raise ScheduleError("后端无输出：%s" % proc.stderr.decode("utf-8", "replace")[-400:])
    try:
        result = json.loads(out)
    except ValueError:
        raise ScheduleError("后端返回非 JSON：%s" % out[:400])
    if result.get("ok") is False:
        message = str(result.get("error") or "后端返回失败")
        # 权限类报错一律补上可执行提示，避免用户只看到一句「无日历访问权限」。
        if "权限" in message and is_macos():
            message = "%s\n  → %s" % (message, CALENDAR_PERMISSION_HINT)
        raise ScheduleError(message)
    return result


# --------------------------------------------------------------------------
# 时间与文本
# --------------------------------------------------------------------------


def parse_dt(value) -> datetime:
    if isinstance(value, datetime):
        return value
    text = str(value or "").strip()
    for pattern in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            parsed = datetime.strptime(text, pattern)
            return parsed
        except ValueError:
            continue
    raise ScheduleError("时间格式无法解析：%s（应为 2026-10-14T09:20:00）" % text)


def iso(value: datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%S")


def label_of(item: dict) -> str:
    return (item.get("label") or "").strip() or KIND_LABEL.get(str(item.get("kind") or "task"), "事项")


def title_of(item: dict) -> str:
    case_no = (item.get("case_no") or "").strip()
    parties = (item.get("parties") or "").strip()
    if case_no and parties:
        subject = "%s·%s" % (case_no, parties)
    elif case_no:
        subject = case_no
    elif parties:
        subject = parties
    else:
        subject = (item.get("title") or "").strip() or "事项"
    return "%s｜%s" % (label_of(item), subject)


def anchor_of(item: dict) -> str:
    given = (item.get("anchor") or "").strip()
    if given:
        return given
    key = "|".join(
        [
            str(item.get("kind") or ""),
            label_of(item),
            str(item.get("case_no") or ""),
            str(item.get("parties") or ""),
            str(item.get("title") or ""),
            iso(parse_dt(item["start"])) if item.get("start") else "",
        ]
    )
    return DEFAULT_ANCHOR_PREFIX + hashlib.sha1(key.encode("utf-8")).hexdigest()[:8].upper()


def offsets_of(item: dict) -> List[int]:
    raw = item.get("offsets", item.get("remind_offsets", item.get("reminders")))
    if raw is None:
        raw = DEFAULT_OFFSETS.get(str(item.get("kind") or "task"), [0])
    try:
        return sorted({int(value) for value in raw}, reverse=True)
    except (TypeError, ValueError):
        raise ScheduleError("offsets 应为整数列表，收到：%r" % (raw,))


# --------------------------------------------------------------------------
# 条目归一化
# -------------------------------------------------------------------------- 


def normalize(raw: dict) -> dict:
    item = dict(raw)
    if not item.get("start"):
        raise ScheduleError("条目缺少 start（开始时间）：%s" % title_of(item))
    start = parse_dt(item["start"])
    all_day = bool(item.get("all_day"))
    if item.get("end"):
        end = parse_dt(item["end"])
    else:
        end = start + (timedelta(hours=23, minutes=59) if all_day else timedelta(hours=2))
    if end <= start:
        end = start + timedelta(hours=2)

    # 期限类默认落截止日当天 09:00、时长 30 分钟（除非显式给了 deadline_clock）
    if str(item.get("kind")) == "deadline" and not item.get("deadline_clock"):
        start = datetime.combine(start.date(), time(9, 0))
        end = start + timedelta(minutes=30)
        all_day = False

    item["start_dt"] = start
    item["end_dt"] = end
    item["all_day"] = all_day
    item["anchor_value"] = anchor_of(item)
    item["title_value"] = title_of(item)
    item["calendar_event"] = bool(item.get("calendar_event", True))
    item["remind"] = bool(item.get("remind", True))
    return item


def detail_notes(item: dict) -> str:
    subject = " ".join(x for x in [(item.get("case_no") or "").strip(), (item.get("parties") or "").strip()] if x)
    lines = ["%s：%s" % (label_of(item), subject or (item.get("title") or "事项"))]
    if item.get("all_day"):
        lines.append("时间：%s（全天）" % item["start_dt"].date().isoformat())
    else:
        lines.append(
            "时间：%s 至 %s" % (item["start_dt"].strftime("%Y-%m-%d %H:%M"), item["end_dt"].strftime("%H:%M"))
        )
    for key, prefix in (("location", "地点"), ("source", "来源"), ("basis", "推算依据"), ("notes", "")):
        value = (item.get(key) or "").strip()
        if value:
            lines.append(("%s：%s" % (prefix, value)) if prefix else value)
    return "\n".join(lines)


def reminder_specs(item: dict) -> List[dict]:
    """生成提醒档位；已过期的档位跳过，返回空表示不建提醒。"""
    if not item.get("remind"):
        return []
    today = date.today()
    start = item["start_dt"]
    specs = []
    for offset in offsets_of(item):
        if offset == 0:
            fire = datetime.combine(start.date(), REMIND_TIME_SAMEDAY)
            if not item.get("all_day") and start.time() <= REMIND_TIME_SAMEDAY:
                fire = start - timedelta(minutes=90)
            tag = "当天"
        else:
            fire = datetime.combine(start.date() - timedelta(days=offset), REMIND_TIME_EARLY)
            tag = "T-%d" % offset
        if fire.date() < today:
            continue
        specs.append(
            {
                "offset": offset,
                "anchor": "%s-T%d" % (item["anchor_value"], offset),
                "title": "【%s】%s" % (tag, item["title_value"]),
                "due": fire,
                "tag": tag,
            }
        )
    return specs


def load_items(path: str) -> Tuple[dict, List[dict]]:
    source = sys.stdin.read() if path == "-" else Path(path).expanduser().read_text(encoding="utf-8-sig")
    try:
        data = json.loads(source)
    except ValueError as exc:
        raise ScheduleError("清单不是合法 JSON：%s" % exc)
    if isinstance(data, list):
        data = {"items": data}
    items = data.get("items")
    if not isinstance(items, list) or not items:
        raise ScheduleError("清单缺少 items 数组")
    return data, [normalize(item) for item in items]


def containers(cli: argparse.Namespace, data: dict) -> Tuple[str, str]:
    calendar = cli.calendar or data.get("calendar") or DEFAULT_CALENDAR
    reminder_list = cli.reminder_list or data.get("reminder_list") or DEFAULT_REMINDER_LIST
    return str(calendar), str(reminder_list)


# --------------------------------------------------------------------------
# 读权限体检
# --------------------------------------------------------------------------


CALENDAR_PERMISSION_HINT = (
    "到「系统设置 → 隐私与安全性 → 日历／提醒事项」，勾选当前使用本技能的应用（Codex／WorkBuddy／千问办公／常威律师 DSH），"
    "权限必须选「完全访问」，改完重启该应用再重试"
)
READ_ONLY_HINT = CALENDAR_PERMISSION_HINT + "；只给「仅写入」会让写入成功但读取被拒，查重与按锚点撤销都会失效"


def read_access_problems(reminder_list: str = DEFAULT_REMINDER_LIST) -> List[str]:
    """检查是否具备读取权限。

    macOS 允许把日历权限授成「仅写入」：此时写入能成功，但读取与删除全被拒绝。
    这会让防重复与按锚点撤销同时失效，写入的条目变成无法管理，因此必须在写入前拦截。
    """
    problems: List[str] = []
    now = datetime.now()
    try:
        call_ek({"cmd": "list_events", "from": iso(now - timedelta(days=1)), "to": iso(now + timedelta(days=1))})
    except ScheduleError as exc:
        if "权限" in str(exc):
            problems.append("日历只有「仅写入」权限，读取被拒绝：查重与按锚点撤销都会失效。" + READ_ONLY_HINT)
    try:
        call_ek({"cmd": "list_reminders", "list": reminder_list})
    except ScheduleError as exc:
        if "权限" in str(exc):
            problems.append("提醒事项只有「仅写入」权限，读取被拒绝：提醒档位的查重与撤销会失效。" + READ_ONLY_HINT)
    return problems


# --------------------------------------------------------------------------
# doctor
# --------------------------------------------------------------------------


def cmd_doctor(args: argparse.Namespace) -> int:
    print("材料代办录入 · 日程写入自检")
    print("  平台    ：%s（%s）" % (platform.system(), platform.machine()))
    print("  后端    ：%s（%s）" % (EK_BIN, "存在" if EK_BIN.exists() else "缺失"))
    if not is_macos():
        print("  结论    ：当前不是 macOS，无法直写日历与提醒；用 ics 子命令导出 .ics 供系统日历／桌面日历客户端导入。")
        print("")
        print("本技能可能触发的系统授权（除 Windows 钉钉通道外不联网，钉钉通道会把日程标题与时间上传钉钉）：")
        print("  Windows 若改用 scripts\\win_calendar.ps1 直写本机日历，需先放行日历访问：")
        print("    设置 → 隐私和安全性 → 日历 → 允许应用访问日历")
        print("  运行 .ps1 需要放行脚本执行策略（单次放行即可，不必改全局策略）：")
        print("    powershell -ExecutionPolicy Bypass -File <脚本路径>")
        print("  导出 .ics 后手动导入不需要任何授权。")
        print(json.dumps({"ok": False, "platform": platform.system(), "mode": "ics"}, ensure_ascii=False, indent=2))
        return 0
    try:
        info = call_ek({"cmd": "doctor"})
    except ScheduleError as exc:
        print("  结论    ：后端不可用 —— %s" % exc)
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False, indent=2))
        return 2
    print("  日历授权：%s（可用：%s）" % (info.get("events_auth"), info.get("events_accessible")))
    print("  提醒授权：%s（可用：%s）" % (info.get("reminders_auth"), info.get("reminders_accessible")))
    calendars = info.get("calendars") or []
    lists = info.get("reminder_lists") or []
    print("  日历    ：%s" % "、".join(calendars))
    print("  提醒清单：%s" % "、".join(lists))
    print("")
    print("本技能需要的系统授权（macOS 侧只在本机读写，不联网）：")
    print("  1. 日历        完全访问（读写）——写入日程、查重、按锚点撤销")
    print("  2. 提醒事项    完全访问（读写）——写入分档提醒")
    print("  授权入口：系统设置 → 隐私与安全性 → 日历／提醒事项，勾选当前使用本技能的应用（Codex／WorkBuddy／千问办公／常威律师 DSH）")
    print("  只给「仅写入」会导致查重与撤销失效，脚本会拒绝写入。")
    print("")
    problems = []
    if args.calendar not in calendars:
        problems.append("日历「%s」不存在，apply 时会自动新建" % args.calendar)
    if args.reminder_list not in lists:
        problems.append("提醒清单「%s」不存在，apply 时会自动新建" % args.reminder_list)
    # 同名容器风险：EventKit 按名称取第一个匹配，同名时会写进另一个日历，出现「写了但看不到」。
    dup_calendars = sorted({name for name in calendars if calendars.count(name) > 1})
    dup_lists = sorted({name for name in lists if lists.count(name) > 1})
    if dup_calendars:
        problems.append(
            "存在同名日历：%s。EventKit 取第一个匹配，可能写进你看不到的那一个；"
            "请到「日历」应用里改掉重名（或改名后再用 --calendar 指定）" % "、".join(dup_calendars)
        )
    if dup_lists:
        problems.append("存在同名提醒清单：%s，处理方式同上" % "、".join(dup_lists))
    # 授权状态为「已授权」不等于能读：macOS 的「仅写入」权限下写入成功、读取被拒。
    read_problems = read_access_problems(args.reminder_list)
    problems.extend(read_problems)
    if problems:
        print("  提示    ：")
        for line in problems:
            print("    - %s" % line)
    if read_problems:
        print("  结论    ：写入通道可用但读取被拒，不得直接 apply（写进去无法查重、无法撤销）")
    else:
        print("  结论    ：读写通道均可用，可以执行 plan／apply")
    print(
        json.dumps(
            {
                "ok": not read_problems,
                "platform": platform.system(),
                "calendar": args.calendar,
                "reminder_list": args.reminder_list,
                "calendars": calendars,
                "reminder_lists": lists,
                "read_access": not read_problems,
                "notes": problems,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0 if not read_problems else 2


# --------------------------------------------------------------------------
# plan / apply（macOS）
# --------------------------------------------------------------------------


def write_item(item: dict, calendar: str, reminder_list: str, apply: bool) -> dict:
    anchor = item["anchor_value"]
    start, end = item["start_dt"], item["end_dt"]
    specs = reminder_specs(item)
    summary = {
        "anchor": anchor,
        "title": item["title_value"],
        "start": iso(start),
        "end": iso(end),
        "location": item.get("location") or "",
        "calendar_event": item["calendar_event"],
        "reminders": [{"anchor": spec["anchor"], "title": spec["title"], "due": iso(spec["due"])} for spec in specs],
    }
    if not apply:
        return summary

    if item["calendar_event"]:
        call_ek(
            {
                "cmd": "upsert_event",
                "calendar": calendar,
                "anchor": anchor,
                "title": item["title_value"],
                "start": iso(start),
                "end": iso(end),
                "all_day": bool(item.get("all_day")),
                "location": item.get("location") or "",
                "notes": detail_notes(item),
                "recurrence": None,
            }
        )
    else:
        call_ek({"cmd": "delete_events", "calendar": calendar, "anchor": anchor})

    expected = set()
    for spec in specs:
        call_ek(
            {
                "cmd": "upsert_reminder",
                "list": reminder_list,
                "anchor": spec["anchor"],
                "title": spec["title"],
                "due": iso(spec["due"]),
                "notes": detail_notes(item),
            }
        )
        expected.add(spec["anchor"])
    # 档位调整后，清理同一锚点下多余的旧档位
    existing = call_ek({"cmd": "list_reminders", "list": reminder_list, "include_completed": True}).get("reminders") or []
    for row in existing:
        notes = row.get("notes") or ""
        for line in notes.splitlines():
            line = line.strip()
            if line.startswith("来福ID: ") and line[len("来福ID: ") :].startswith(anchor + "-T"):
                stale = line[len("来福ID: ") :]
                if stale not in expected:
                    call_ek({"cmd": "delete_reminders", "list": reminder_list, "anchor": stale})
    return summary


def run_plan_or_apply(args: argparse.Namespace) -> int:
    data, items = load_items(args.json)
    calendar, reminder_list = containers(args, data)
    apply = bool(args.apply)
    if apply and not is_macos():
        print("当前平台不是 macOS，已改为导出 ICS：%s" % args.out)
        return write_ics(items, args.out, calendar)
    if apply:
        blockers = read_access_problems(reminder_list)
        if blockers:
            raise ScheduleError(
                "读权限不足，已拒绝写入——写进去的条目将无法查重、无法按锚点撤销：\n  - %s\n"
                "若该环境的日历权限无法改为完全访问，请改用 ics 子命令导出 .ics 后导入。" % "\n  - ".join(blockers)
            )
        call_ek({"cmd": "ensure_calendar", "title": calendar})
        call_ek({"cmd": "ensure_list", "title": reminder_list})
    results = []
    for item in items:
        results.append(write_item(item, calendar, reminder_list, apply))
    print(("已写入 %d 条：" % len(results)) if apply else ("预演：将写入 %d 条（加 --apply 执行）：" % len(results)))
    for row in results:
        print("  [%s] %s  %s" % (row["anchor"], row["title"], row["start"]))
        if row["calendar_event"]:
            print("        日历：%s%s" % (calendar, ("　地点：" + row["location"]) if row["location"] else ""))
        else:
            print("        日历：不占（仅提醒）")
        for spec in row["reminders"]:
            print("        提醒：%s  %s" % (spec["due"][:16].replace("T", " "), spec["title"]))
        if not row["reminders"]:
            print("        提醒：无（已过期或不建提醒）")
    print(json.dumps({"applied": apply, "calendar": calendar, "reminder_list": reminder_list, "items": results},
                     ensure_ascii=False, indent=2))
    return 0


# --------------------------------------------------------------------------
# ICS 导出（Windows／任意平台）
# --------------------------------------------------------------------------


def ics_escape(text: str) -> str:
    return str(text).replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\r\n", "\\n").replace("\n", "\\n")


def ics_fold(line: str) -> str:
    """按 75 字节折行（UTF-8 安全）。"""
    raw = line.encode("utf-8")
    if len(raw) <= 75:
        return line
    parts, current = [], b""
    for ch in line:
        encoded = ch.encode("utf-8")
        if len(current) + len(encoded) > 73:
            parts.append(current)
            current = b""
        current += encoded
    parts.append(current)
    out = [parts[0].decode("utf-8")]
    for chunk in parts[1:]:
        out.append(" " + chunk.decode("utf-8"))
    return "\r\n".join(out)


def write_ics(items: Sequence[dict], out_path: str, calendar_name: str = DEFAULT_CALENDAR) -> int:
    # 用带时区的时间生成 DTSTAMP，避免 Python 3.12 起对 utcnow() 的弃用告警。
    now = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Material Intake//Schedule//CN",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "X-WR-CALNAME:%s" % ics_escape(calendar_name),
    ]
    for item in items:
        start, end = item["start_dt"], item["end_dt"]
        notes = detail_notes(item)
        lines += [
            "BEGIN:VEVENT",
            "UID:%s@material-intake" % item["anchor_value"],
            "DTSTAMP:%s" % now,
            "DTSTART:%s" % start.strftime("%Y%m%dT%H%M%S"),
            "DTEND:%s" % end.strftime("%Y%m%dT%H%M%S"),
            "SUMMARY:%s" % ics_escape(item["title_value"]),
        ]
        if item.get("location"):
            lines.append("LOCATION:%s" % ics_escape(item["location"]))
        lines.append("DESCRIPTION:%s" % ics_escape(notes + "\n来福ID: " + item["anchor_value"]))
        lines.append("TRANSP:%s" % ("TRANSPARENT" if not item["calendar_event"] else "OPAQUE"))
        lines.append("X-MICROSOFT-CDO-BUSYSTATUS:%s" % ("FREE" if not item["calendar_event"] else "BUSY"))
        for spec in reminder_specs(item):
            # 提醒用绝对时间写（本地时间转 UTC），不用相对事件开始时间的偏移。
            # 相对写法在全天事件上会算成负值：事件 00:00 开始、当天提醒 07:30，delta 为负，
            # 提醒会被静默丢掉。绝对写法既不会丢，也能保证提醒严格落在 09:00／07:30。
            trigger = spec["due"].astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            lines += [
                "BEGIN:VALARM",
                "ACTION:DISPLAY",
                "DESCRIPTION:%s" % ics_escape(spec["title"]),
                "TRIGGER;VALUE=DATE-TIME:%s" % trigger,
                "END:VALARM",
            ]
        lines.append("END:VEVENT")
    lines.append("END:VCALENDAR")

    out = Path(out_path).expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)
    # 注意：Path.write_text 的 newline 参数要 Python 3.10+，这里用 open 保证 3.9 也能跑。
    with out.open("w", encoding="utf-8", newline="") as handle:
        handle.write("\r\n".join(ics_fold(line) for line in lines) + "\r\n")
    print("已导出日历文件：%s（%d 条）" % (out, len(items)))
    print("导入方式：Windows 用「日历」应用或桌面日历客户端打开该文件；手机可发到微信/邮件后用日历 App 打开。")
    return 0


def cmd_ics(args: argparse.Namespace) -> int:
    data, items = load_items(args.json)
    calendar, _ = containers(args, data)
    return write_ics(items, args.out, calendar)


# --------------------------------------------------------------------------
# list / rm
# --------------------------------------------------------------------------


def cmd_list(args: argparse.Namespace) -> int:
    if not is_macos():
        raise ScheduleError("list 只在 macOS 可用；导出的 .ics 不提供回读")
    start = datetime.now() - timedelta(days=args.days)
    end = datetime.now() + timedelta(days=args.days)
    calendar, reminder_list = args.calendar, args.reminder_list
    events = call_ek(
        {"cmd": "list_events", "calendar": calendar, "from": iso(start), "to": iso(end)}
    ).get("events") or []
    reminders = call_ek({"cmd": "list_reminders", "list": reminder_list}).get("reminders") or []
    rows = []
    for event in events:
        anchor = anchor_in(event.get("notes"))
        if anchor and anchor.startswith(args.prefix):
            rows.append({"type": "事件", "anchor": anchor, "title": event.get("title"), "time": event.get("start")})
    for reminder in reminders:
        anchor = anchor_in(reminder.get("notes"))
        if anchor and anchor.startswith(args.prefix):
            rows.append({"type": "提醒", "anchor": anchor, "title": reminder.get("title"), "time": reminder.get("due") or ""})
    rows.sort(key=lambda row: (row["time"] or "", row["type"]))
    print("带 %s 前缀的条目共 %d 条：" % (args.prefix, len(rows)))
    for row in rows:
        print("  [%s] %s  %s  %s" % (row["anchor"], row["type"], (row["time"] or "")[:16].replace("T", " "), row["title"]))
    print(json.dumps({"rows": rows}, ensure_ascii=False, indent=2))
    return 0


def anchor_in(notes: Optional[str]) -> Optional[str]:
    for line in (notes or "").splitlines():
        line = line.strip()
        if line.startswith("来福ID: "):
            return line[len("来福ID: ") :].strip()
    return None


def cmd_rm(args: argparse.Namespace) -> int:
    if not is_macos():
        raise ScheduleError("rm 只在 macOS 可用；Windows 上请用 win_calendar.ps1 rm -Anchor 或在日历客户端里按锚点搜索后删除")
    anchor = args.anchor.strip()
    if not re.fullmatch(r"[A-Za-z0-9\-]+", anchor):
        raise ScheduleError("锚点格式不正确：%s" % anchor)
    if not args.apply:
        print("预演：将删除锚点 %s 的事件及其全部提醒档位（加 --apply 执行）" % anchor)
        print(json.dumps({"applied": False, "anchor": anchor}, ensure_ascii=False, indent=2))
        return 0
    blockers = read_access_problems(args.reminder_list)
    if blockers:
        raise ScheduleError(
            "读权限不足，无法按锚点撤销（撤销依赖读取备注里的锚点）：\n  - %s" % "\n  - ".join(blockers)
        )
    # 先删本体的精确锚点，再按「锚点-T」前缀清理提醒档位，避免误伤同前缀的其他锚点。
    event = call_ek({"cmd": "delete_events", "calendar": args.calendar, "anchor": anchor})
    exact = call_ek({"cmd": "delete_reminders", "list": args.reminder_list, "anchor": anchor})
    tiers = call_ek({"cmd": "delete_reminders", "list": args.reminder_list, "anchor_prefix": anchor + "-T"})
    deleted = int(event.get("deleted") or 0) + int(exact.get("deleted") or 0) + int(tiers.get("deleted") or 0)
    print("已删除锚点 %s：事件 %s 条，提醒 %s 条（含档位 %s 条）"
          % (anchor, event.get("deleted"), int(exact.get("deleted") or 0) + int(tiers.get("deleted") or 0), tiers.get("deleted")))
    print(json.dumps({"applied": True, "anchor": anchor, "deleted_total": deleted,
                      "event": event, "reminders_exact": exact, "reminder_tiers": tiers},
                     ensure_ascii=False, indent=2))
    return 0


# --------------------------------------------------------------------------
# 入口
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="schedule_write", description="材料代办录入 · 日程写入（macOS 直写；其他平台导出 ICS）")
    parser.add_argument("--calendar", default=DEFAULT_CALENDAR, help="目标日历，缺省「工作」")
    parser.add_argument("--reminder-list", default=DEFAULT_REMINDER_LIST, help="目标提醒清单，缺省「提醒」")
    sub = parser.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor", help="平台、后端、授权与容器自检")
    doctor.set_defaults(func=cmd_doctor)

    # plan 不接 --apply：预演就是预演，避免「plan --apply」意外落盘。
    plan = sub.add_parser("plan", help="校验清单并打印将要写入的内容（不写）")
    plan.add_argument("--json", required=True, help="日程清单 JSON 路径，- 表示从标准输入读")
    plan.add_argument("--out", default="日程清单.ics", help="非 macOS 时导出的 ICS 路径")
    plan.set_defaults(func=run_plan_or_apply, apply=False)

    apply_cmd = sub.add_parser("apply", help="写入日历与提醒（macOS）；非 macOS 时改为导出 ICS")
    apply_cmd.add_argument("--json", required=True, help="日程清单 JSON 路径，- 表示从标准输入读")
    apply_cmd.add_argument("--out", default="日程清单.ics", help="非 macOS 时导出的 ICS 路径")
    apply_cmd.set_defaults(func=run_plan_or_apply, apply=True)

    ics = sub.add_parser("ics", help="导出 .ics（Windows／任意平台）")
    ics.add_argument("--json", required=True)
    ics.add_argument("--out", default="日程清单.ics")
    ics.set_defaults(func=cmd_ics)

    list_cmd = sub.add_parser("list", help="列出本工具写入的条目（按锚点前缀）")
    list_cmd.add_argument("--days", type=int, default=60)
    list_cmd.add_argument("--prefix", default=DEFAULT_ANCHOR_PREFIX)
    list_cmd.set_defaults(func=cmd_list)

    rm = sub.add_parser("rm", help="按锚点撤销条目及其全部提醒档位")
    rm.add_argument("--anchor", required=True)
    rm.add_argument("--apply", action="store_true")
    rm.set_defaults(func=cmd_rm)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    try:
        return args.func(args)
    except ScheduleError as exc:
        print("错误：%s" % exc, file=sys.stderr)
        return 2
    except OSError as exc:
        # 路径写错、文件被系统拦下时给一行可读提示，不甩整段调用栈。
        target = getattr(exc, "filename", "") or ""
        detail = ("（%s）" % exc.strerror) if getattr(exc, "strerror", None) else ""
        print("错误：无法访问 %s%s" % (target, detail), file=sys.stderr)
        print("  → 检查路径是否存在、是否有读取权限；macOS 被拦时到"
              "「系统设置 → 隐私与安全性 → 文件与文件夹」放行，Windows 检查文件是否被占用", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
