# 材料代办录入 · 日程写入（Windows 原生日历后端）
#
# 用途：把日程清单 JSON 直接写进 Windows 系统日历存储（Windows.ApplicationModel.Appointments），
#       条目随后出现在本机日历（锁屏、任务栏时钟弹窗、日历小组件）中，无需手工导入。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File win_calendar.ps1 doctor
#   powershell -ExecutionPolicy Bypass -File win_calendar.ps1 plan  -Json 产出\日程清单.json
#   powershell -ExecutionPolicy Bypass -File win_calendar.ps1 apply -Json 产出\日程清单.json
#   powershell -ExecutionPolicy Bypass -File win_calendar.ps1 list  -Days 60
#   powershell -ExecutionPolicy Bypass -File win_calendar.ps1 rm    -Anchor LR-MI-XXXXXXXX -Apply
#
# 三条底线与 Python 侧一致：
#   1. 只操作备注里带「来福ID: <锚点>」的条目，不碰手工创建的事件。
#   2. 同一锚点先查后写，重复执行不产生重复条目。
#   3. 缺省只预演，加了 -Apply 才落盘；撤销同样先预演。

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("doctor", "plan", "apply", "list", "rm")]
    [string]$Command,

    [string]$Json,
    [string]$Calendar = "日历",
    [switch]$NoTiers,
    [int]$Days = 60,
    [string]$Anchor,
    [string]$Prefix = "LR-MI-",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$script:AnchorPrefix = "LR-MI-"
$script:KindLabel = @{ hearing = "开庭"; deadline = "期限"; meeting = "会议"; task = "待办"; onsite = "驻场" }
$script:DefaultOffsets = @{
    hearing  = @(7, 3, 1, 0)
    deadline = @(7, 3, 1, 0)
    onsite   = @(7, 3, 1, 0)
    meeting  = @(1, 0)
    task     = @(0)
}
$script:RemindTimeEarly = [timespan]::FromHours(9)
$script:RemindTimeSameDay = [timespan]::FromHours(7.5)

# ------------------------------------------------------------------ WinRT 桥接

Add-Type -AssemblyName System.Runtime.WindowsRuntime

$script:AsTaskOperation = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
$script:AsTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
    })[0]

$null = [Windows.ApplicationModel.Appointments.AppointmentManager, Windows.ApplicationModel.Appointments, ContentType = WindowsRuntime]

function Wait-Operation($operation, [type]$resultType) {
    $task = $script:AsTaskOperation.MakeGenericMethod($resultType).Invoke($null, @($operation))
    if (-not $task.Wait(60000)) { throw "日历接口调用超时" }
    return $task.Result
}

function Wait-Action($operation) {
    $task = $script:AsTaskAction.Invoke($null, @($operation))
    if (-not $task.Wait(60000)) { throw "日历接口调用超时" }
}

$script:AppointmentType = [Windows.ApplicationModel.Appointments.Appointment, Windows.ApplicationModel.Appointments, ContentType = WindowsRuntime]
$script:AppointmentListType = [System.Collections.Generic.IReadOnlyList[Windows.ApplicationModel.Appointments.Appointment]]
$script:CalendarListType = [System.Collections.Generic.IReadOnlyList[Windows.ApplicationModel.Appointments.AppointmentCalendar]]

function Get-CalendarStore {
    $operation = [Windows.ApplicationModel.Appointments.AppointmentManager]::RequestStoreAsync([Windows.ApplicationModel.Appointments.AppointmentStoreAccessType]::AllCalendarsReadWrite)
    $store = $null
    try {
        $store = Wait-Operation $operation ([Windows.ApplicationModel.Appointments.AppointmentStore])
    } catch {
        throw ("无法访问 Windows 日历存储：$($_.Exception.Message)`n$(Get-CalendarPermissionHint)")
    }
    if (-not $store) {
        throw ("Windows 日历存储返回空，通常是系统未放行日历访问。`n$(Get-CalendarPermissionHint)")
    }
    return $store
}

function Get-CalendarPermissionHint {
    return "提示：到「设置 → 隐私和安全性 → 日历」允许应用访问日历，并确认日历／邮件客户端已配置账户；" +
           "若为企业策略禁用，或本机不提供日历存储，改用 python scripts\schedule_write.py ics 导出 .ics 后导入。"
}

function Get-TargetCalendar($store) {
    $calendars = Wait-Operation ($store.FindAppointmentCalendarsAsync()) $script:CalendarListType
    foreach ($item in $calendars) {
        if ($item.DisplayName -eq $Calendar -and -not $item.IsReadOnly) { return $item }
    }
    $writable = @($calendars | Where-Object { -not $_.IsReadOnly })
    if ($writable.Count -gt 0) {
        Write-Warning "未找到名为「$Calendar」的可写日历，改用「$($writable[0].DisplayName)」"
        return $writable[0]
    }
    throw "日历存储中没有可写日历"
}

# ------------------------------------------------------------------ 文本与时间

function ConvertTo-IsoTime([datetime]$value) { return $value.ToString("yyyy-MM-ddTHH:mm:ss") }

function ConvertFrom-AnyTime($value) {
    if ($value -is [datetime]) { return $value }
    $text = ([string]$value).Trim()
    foreach ($pattern in @("yyyy-MM-ddTHH:mm:ss", "yyyy-MM-ddTHH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd")) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($text, $pattern, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }
    }
    throw "时间格式无法解析：$text（应为 2026-10-14T09:20:00）"
}

function Get-Label($item) {
    $label = ([string]$item.label).Trim()
    if ($label) { return $label }
    $kind = if ($item.kind) { [string]$item.kind } else { "task" }
    if ($script:KindLabel.ContainsKey($kind)) { return $script:KindLabel[$kind] }
    return "事项"
}

function Get-Title($item) {
    $caseNo = ([string]$item.case_no).Trim()
    $parties = ([string]$item.parties).Trim()
    if ($caseNo -and $parties) { $subject = "$caseNo·$parties" }
    elseif ($caseNo) { $subject = $caseNo }
    elseif ($parties) { $subject = $parties }
    else { $subject = ([string]$item.title).Trim(); if (-not $subject) { $subject = "事项" } }
    return "$(Get-Label $item)｜$subject"
}

# 锚点算法与 schedule_write.py 完全一致：kind|label|case_no|parties|title|iso(原始 start)
function Get-Anchor($item) {
    $given = ([string]$item.anchor).Trim()
    if ($given) { return $given }
    $kind = ([string]$item.kind).Trim()
    $label = Get-Label $item
    $caseNo = [string]$item.case_no
    $parties = [string]$item.parties
    $title = [string]$item.title
    $startText = if ($item.start) { ConvertTo-IsoTime (ConvertFrom-AnyTime $item.start) } else { "" }
    $key = @($kind, $label, $caseNo, $parties, $title, $startText) -join "|"
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))
    $hex = ([System.BitConverter]::ToString($bytes)).Replace("-", "")
    return $script:AnchorPrefix + $hex.Substring(0, 8).ToUpper()
}

function Get-Offsets($item) {
    # 口径与 Python offsets_of() 一致，两点都要守住：
    #   1) 不能用 -not $raw 判断"有没有给档位"——PowerShell 里 @(0) 与 @() 都是假值，
    #      会把显式给的「只当天提醒」与「不要提醒」误当成没给，静默退回类型默认档，
    #      于是 .ics 与本机通道对同一条日程的档位集合不一致，混用时查重口径会飘；
    #   2) 显式写 null 视为"没给"（与 Python 的 item.get(...) 行为一致），走类型默认。
    $names = @($item.PSObject.Properties.Name)
    $raw = $null
    foreach ($key in @("offsets", "remind_offsets", "reminders")) {
        if (($names -contains $key) -and ($null -ne $item.$key)) { $raw = $item.$key; break }
    }
    if ($null -eq $raw) {
        $kind = if ($item.kind) { [string]$item.kind } else { "task" }
        if ($script:DefaultOffsets.ContainsKey($kind)) { $raw = $script:DefaultOffsets[$kind] } else { $raw = @(0) }
    }
    $values = @()
    foreach ($value in @($raw)) { $values += [int]$value }
    return @($values | Sort-Object -Descending -Unique)
}

function Get-Normalized($raw) {
    $item = $raw
    if (-not $item.start) { throw "条目缺少 start（开始时间）：$(Get-Title $item)" }
    $start = ConvertFrom-AnyTime $item.start
    $allDay = [bool]$item.all_day
    if ($item.end) {
        $end = ConvertFrom-AnyTime $item.end
    } elseif ($allDay) {
        $end = $start.AddHours(23).AddMinutes(59)
    } else {
        $end = $start.AddHours(2)
    }
    if ($end -le $start) { $end = $start.AddHours(2) }
    if (([string]$item.kind) -eq "deadline" -and -not $item.deadline_clock) {
        $start = $start.Date.AddHours(9)
        $end = $start.AddMinutes(30)
        $allDay = $false
    }
    return [pscustomobject]@{
        Raw       = $item
        Start     = $start
        End       = $end
        AllDay    = $allDay
        Anchor    = Get-Anchor $item
        Title     = Get-Title $item
        OnCalendar = if ($null -eq $item.calendar_event) { $true } else { [bool]$item.calendar_event }
        Remind    = if ($null -eq $item.remind) { $true } else { [bool]$item.remind }
    }
}

function Get-Details($entry) {
    $item = $entry.Raw
    $subject = (@(([string]$item.case_no).Trim(), ([string]$item.parties).Trim()) | Where-Object { $_ }) -join " "
    if (-not $subject) { $subject = ([string]$item.title).Trim(); if (-not $subject) { $subject = "事项" } }
    $lines = @("$(Get-Label $item)：$subject")
    if ($entry.AllDay) {
        $lines += "时间：$($entry.Start.ToString('yyyy-MM-dd'))（全天）"
    } else {
        $lines += "时间：$($entry.Start.ToString('yyyy-MM-dd HH:mm')) 至 $($entry.End.ToString('HH:mm'))"
    }
    foreach ($pair in @(@("location", "地点"), @("source", "来源"), @("basis", "推算依据"))) {
        $value = ([string]$item.($pair[0])).Trim()
        if ($value) { $lines += "$($pair[1])：$value" }
    }
    $notes = ([string]$item.notes).Trim()
    if ($notes) { $lines += $notes }
    $lines += "来福ID: $($entry.Anchor)"
    return ($lines -join "`r`n")
}

function Get-TierPlan($entry) {
    if (-not $entry.Remind) { return @() }
    $today = (Get-Date).Date
    $specs = @()
    foreach ($offset in (Get-Offsets $entry.Raw)) {
        if ($offset -eq 0) {
            $fire = $entry.Start.Date.AddHours(7).AddMinutes(30)
            if (-not $entry.AllDay -and $entry.Start.TimeOfDay -le $script:RemindTimeSameDay) { $fire = $entry.Start.AddMinutes(-90) }
            $tag = "当天"
        } else {
            $fire = $entry.Start.Date.AddDays(-$offset).AddHours(9)
            $tag = "T-$offset"
        }
        if ($fire.Date -lt $today) { continue }
        $specs += [pscustomobject]@{
            Offset = $offset
            Anchor = "$($entry.Anchor)-T$offset"
            Title  = "【$tag】$($entry.Title)"
            Fire   = $fire
        }
    }
    return $specs
}

function Get-Items([string]$path) {
    if (-not (Test-Path $path)) { throw "找不到清单文件：$path" }
    $data = Get-Content -Path $path -Encoding UTF8 -Raw | ConvertFrom-Json
    if (-not $data.items) { throw "清单缺少 items 数组" }
    $entries = @()
    foreach ($item in $data.items) { $entries += Get-Normalized $item }
    return $entries
}

# ------------------------------------------------------------------ 既有条目检索

function Get-ExistingAppointments($store, [datetime]$from, [datetime]$to) {
    $start = [datetimeoffset]::new($from)
    $span = $to - $from
    if ($span.TotalDays -le 0) { $span = [timespan]::FromDays(1) }
    $list = Wait-Operation ($store.FindAppointmentsAsync($start, $span)) $script:AppointmentListType
    return @($list)
}

function Get-AnchorFromDetails([string]$details) {
    if (-not $details) { return $null }
    foreach ($line in ($details -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("来福ID: ")) { return $trimmed.Substring(6).Trim() }
    }
    return $null
}

# 读出完整条目（默认检索不含 Details，需逐条取回）
function Get-FullAppointment($store, $appointment) {
    return Wait-Operation ($store.GetAppointmentAsync($appointment.LocalId)) $script:AppointmentType
}

function Find-Mine($store, [datetime]$from, [datetime]$to, [string]$anchorPrefix) {
    $found = @()
    foreach ($candidate in (Get-ExistingAppointments $store $from $to)) {
        $full = Get-FullAppointment $store $candidate
        $anchor = Get-AnchorFromDetails $full.Details
        if ($anchor -and $anchor.StartsWith($anchorPrefix)) {
            $found += [pscustomobject]@{ Anchor = $anchor; Appointment = $full }
        }
    }
    return $found
}

# 把清单条目的属性写到约会对象上；新建与更新共用，避免两处逻辑漂移
function Set-AppointmentProps($appointment, $entry, $tier) {
    if ($tier) {
        $appointment.Subject = $tier.Title
        $appointment.StartTime = [datetimeoffset]::new($tier.Fire)
        $appointment.Duration = [timespan]::FromMinutes(15)
        $appointment.AllDay = $false
        $appointment.Location = ""
        $appointment.Details = "$($tier.Title)`r`n分档提醒（由材料代办录入写入；正文见同日主条目）`r`n来福ID: $($tier.Anchor)"
        $appointment.BusyStatus = [Windows.ApplicationModel.Appointments.AppointmentBusyStatus]::Free
        $appointment.Reminder = [timespan]::Zero
        return
    }
    $appointment.Subject = $entry.Title
    $appointment.StartTime = [datetimeoffset]::new($entry.Start)
    $appointment.Duration = $entry.End - $entry.Start
    $appointment.AllDay = $entry.AllDay
    $appointment.Location = [string]$entry.Raw.location
    $appointment.Details = Get-Details $entry
    $appointment.BusyStatus = if ($entry.OnCalendar) {
        [Windows.ApplicationModel.Appointments.AppointmentBusyStatus]::Busy
    } else {
        [Windows.ApplicationModel.Appointments.AppointmentBusyStatus]::Free
    }
    $sameDay = @(Get-TierPlan $entry | Where-Object { $_.Offset -eq 0 })
    if ($sameDay.Count -gt 0 -and $sameDay[0].Fire -gt (Get-Date)) {
        $appointment.Reminder = $sameDay[0].Fire - $entry.Start
    } else {
        $appointment.Reminder = [timespan]::Zero
    }
}

# ------------------------------------------------------------------ 子命令

function Invoke-Doctor {
    Write-Host "材料代办录入 · 本机日历后端自检"
    Write-Host "  平台    ：$([System.Environment]::OSVersion.VersionString)"
    $osBuild = [System.Environment]::OSVersion.Version.Build
    if ($osBuild -lt 22000) {
        Write-Warning "本技能按 Windows 11 及以上验证，当前系统 build $osBuild（低于 22000）。日历存储接口在旧版系统上的行为未经验证，结果仅供参考。"
    }
    Write-Host "  PowerShell：$($PSVersionTable.PSVersion)"
    Write-Host ""
    Write-Host "本工具需要的系统授权（本通道不联网，只在本机读写）："
    Write-Host "  1. 日历访问：设置 → 隐私和安全性 → 日历 → 允许应用访问日历"
    Write-Host "  2. 脚本执行策略：用 -ExecutionPolicy Bypass 单次放行即可，不必改全局策略"
    Write-Host "  被拒绝时的替代通道：python scripts\schedule_write.py ics 导出 .ics 后手动导入（无需授权）"
    Write-Host ""
    $store = Get-CalendarStore
    $calendars = Wait-Operation ($store.FindAppointmentCalendarsAsync()) $script:CalendarListType
    Write-Host "  日历存储：可用，共 $($calendars.Count) 个日历"
    foreach ($item in $calendars) {
        $mode = if ($item.IsReadOnly) { "只读" } else { "可写" }
        Write-Host "    - $($item.DisplayName)（$mode）"
    }
    $target = Get-TargetCalendar $store
    Write-Host "  写入目标：$($target.DisplayName)"
    Write-Host ""
    Write-Host "结论：可用。写入后条目出现在本机日历（锁屏、任务栏时钟弹窗、日历小组件）。"
    [pscustomobject]@{ ok = $true; calendars = @($calendars | ForEach-Object { $_.DisplayName }); target = $target.DisplayName } | ConvertTo-Json -Depth 4
}

function Invoke-Write([bool]$dryRun) {
    if (-not $Json) { throw "缺少 -Json 参数" }
    $entries = Get-Items $Json
    $store = Get-CalendarStore
    $target = Get-TargetCalendar $store
    $from = ($entries | ForEach-Object { $_.Start } | Sort-Object)[0].AddDays(-400)
    $to = ($entries | ForEach-Object { $_.End } | Sort-Object)[-1].AddDays(400)
    $existing = Find-Mine $store $from $to $script:AnchorPrefix

    $plan = @()
    foreach ($entry in $entries) {
        $hit = @($existing | Where-Object { $_.Anchor -eq $entry.Anchor })
        $plan += [pscustomobject]@{
            Kind   = "主条目"
            Action = if ($hit.Count -gt 0) { "更新" } else { "新建" }
            Anchor = $entry.Anchor
            Title  = $entry.Title
            Start  = $entry.Start.ToString("yyyy-MM-dd HH:mm")
            Scope  = if ($entry.OnCalendar) { "占用日历" } else { "空闲（不占忙）" }
            Entry  = $entry
            Tier   = $null
        }
        if ($NoTiers) { continue }
        foreach ($tier in (Get-TierPlan $entry)) {
            $tierHit = @($existing | Where-Object { $_.Anchor -eq $tier.Anchor })
            $plan += [pscustomobject]@{
                Kind   = "提醒档位"
                Action = if ($tierHit.Count -gt 0) { "更新" } else { "新建" }
                Anchor = $tier.Anchor
                Title  = $tier.Title
                Start  = $tier.Fire.ToString("yyyy-MM-dd HH:mm")
                Scope  = "空闲（不占忙）"
                Entry  = $entry
                Tier   = $tier
            }
        }
    }

    Write-Host "$(if ($dryRun) { '预演' } else { '执行' })：目标日历「$($target.DisplayName)」，共 $($plan.Count) 条"
    foreach ($row in $plan) {
        Write-Host ("  [{0}] {1} {2}　{3}　{4}　{5}" -f $row.Anchor, $row.Action, $row.Kind, $row.Start, $row.Scope, $row.Title)
    }
    if ($dryRun) {
        Write-Host ""
        Write-Host "预演结束（未写入）。确认后加 -Apply。"
        [pscustomobject]@{ applied = $false; calendar = $target.DisplayName; count = $plan.Count } | ConvertTo-Json -Depth 4
        return
    }

    $created = 0
    $updated = 0
    foreach ($row in $plan) {
        $hit = @($existing | Where-Object { $_.Anchor -eq $row.Anchor })
        if ($hit.Count -gt 0) {
            # 更新只能改从存储取回的原对象（LocalId 只读），改完存回同一日历
            $appointment = $hit[0].Appointment
            Set-AppointmentProps $appointment $row.Entry $row.Tier
            $owner = Wait-Operation ($store.GetAppointmentCalendarAsync($appointment.CalendarId)) ([Windows.ApplicationModel.Appointments.AppointmentCalendar])
            Wait-Action ($owner.SaveAppointmentAsync($appointment))
            $updated++
        } else {
            $appointment = $script:AppointmentType::new()
            Set-AppointmentProps $appointment $row.Entry $row.Tier
            Wait-Action ($target.SaveAppointmentAsync($appointment))
            $created++
        }
    }
    Write-Host "完成：新建 $created 条，更新 $updated 条。"
    Write-Host "撤销方式：win_calendar.ps1 rm -Anchor LR-MI-XXXXXXXX -Apply，或在日历中按「来福ID」搜索后删除。"
    [pscustomobject]@{ applied = $true; calendar = $target.DisplayName; created = $created; updated = $updated } | ConvertTo-Json -Depth 4
}

function Invoke-List {
    $store = Get-CalendarStore
    $from = (Get-Date).Date.AddDays(-7)
    $to = (Get-Date).Date.AddDays($Days)
    $found = Find-Mine $store $from $to $Prefix
    Write-Host "本工具写入的条目（$($from.ToString('yyyy-MM-dd')) 起 $Days 天）：$($found.Count) 条"
    foreach ($row in ($found | Sort-Object { $_.Appointment.StartTime })) {
        Write-Host ("  [{0}] {1}　{2}" -f $row.Anchor, $row.Appointment.StartTime.ToString("yyyy-MM-dd HH:mm"), $row.Appointment.Subject)
    }
    [pscustomobject]@{ count = $found.Count; anchors = @($found | ForEach-Object { $_.Anchor }) } | ConvertTo-Json -Depth 4
}

function Invoke-Remove {
    if (-not $Anchor -and -not $Prefix) { throw "需指定 -Anchor 或 -Prefix" }
    if ($Anchor -and -not ($Anchor -match '^[A-Za-z0-9\-]+$')) { throw "锚点格式不正确：$Anchor" }
    $store = Get-CalendarStore
    $matchPrefix = if ($Anchor) { $Anchor } else { $Prefix }
    $from = (Get-Date).Date.AddDays(-400)
    $to = (Get-Date).Date.AddDays(800)
    $mine = Find-Mine $store $from $to $matchPrefix
    $targets = @()
    foreach ($row in $mine) {
        if ($Anchor) {
            # 精确锚点 + 同名档位（锚点-Tn），不误伤同前缀的其他锚点
            if ($row.Anchor -eq $Anchor -or $row.Anchor.StartsWith("$Anchor-T")) { $targets += $row }
        } else {
            $targets += $row
        }
    }
    if (-not $targets) {
        Write-Host "未找到匹配条目，无需清理。"
        [pscustomobject]@{ applied = $false; deleted = 0 } | ConvertTo-Json -Depth 4
        return
    }
    Write-Host "命中 $($targets.Count) 条："
    foreach ($row in $targets) {
        Write-Host ("  [{0}] {1}　{2}" -f $row.Anchor, $row.Appointment.StartTime.ToString("yyyy-MM-dd HH:mm"), $row.Appointment.Subject)
    }
    if (-not $Apply) {
        Write-Host ""
        Write-Host "预演（未删除，加 -Apply 执行）"
        [pscustomobject]@{ applied = $false; deleted = 0; planned = $targets.Count } | ConvertTo-Json -Depth 4
        return
    }
    $deleted = 0
    foreach ($row in $targets) {
        # 删除方法挂在日历对象上，不在存储对象上
        $owner = Wait-Operation ($store.GetAppointmentCalendarAsync($row.Appointment.CalendarId)) ([Windows.ApplicationModel.Appointments.AppointmentCalendar])
        Wait-Action ($owner.DeleteAppointmentAsync($row.Appointment.LocalId))
        $deleted++
    }
    Write-Host "已删除 $deleted 条（全部为本工具写入的条目）。"
    [pscustomobject]@{ applied = $true; deleted = $deleted } | ConvertTo-Json -Depth 4
}

switch ($Command) {
    "doctor" { Invoke-Doctor }
    "plan" { Invoke-Write $true }
    "apply" { Invoke-Write $false }
    "list" { Invoke-List }
    "rm" { Invoke-Remove }
}
