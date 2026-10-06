# 材料代办录入 · 期限提醒（Windows 系统通知后端）
#
# 用途：把日程清单里的各档位（T-7／T-3／T-1／当天）排定成 Windows 系统通知，
#       到点由系统通知平台自动弹出，出现在右下角通知区；不依赖任何日历应用。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File win_remind.ps1 doctor
#   powershell -ExecutionPolicy Bypass -File win_remind.ps1 install
#   powershell -ExecutionPolicy Bypass -File win_remind.ps1 plan  -Json 产出\日程清单.json
#   powershell -ExecutionPolicy Bypass -File win_remind.ps1 apply -Json 产出\日程清单.json
#   powershell -ExecutionPolicy Bypass -File win_remind.ps1 list
#   powershell -ExecutionPolicy Bypass -File win_remind.ps1 clear -Anchor LR-MI-XXXXXXXX -Apply
#   powershell -ExecutionPolicy Bypass -File win_remind.ps1 clear -Prefix LR-MI- -Apply
#
# 三条底线与其余后端一致：只操作带「来福ID」锚点的通知；先查后写不重复；缺省只预演。

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("doctor", "install", "uninstall", "enable-notifications", "plan", "apply", "list", "clear", "selftest", "preview")]
    [string]$Command,
    [string]$Json,
    [string]$Anchor,
    [string]$Prefix = "LR-MI-",
    [switch]$Apply,
    [int]$DelaySeconds = 40
)

$ErrorActionPreference = "Stop"

$script:Aumid = "MaterialIntake.Reminder"
$script:Group = "mi-remind"
$script:AnchorPrefix = "LR-MI-"
$script:Lnk = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\材料代办录入提醒.lnk"
$script:KindLabel = @{ hearing = "开庭"; deadline = "期限"; meeting = "会议"; task = "待办"; onsite = "驻场" }
$script:DefaultOffsets = @{
    hearing  = @(7, 3, 1, 0)
    deadline = @(7, 3, 1, 0)
    onsite   = @(7, 3, 1, 0)
    meeting  = @(1, 0)
    task     = @(0)
}

# ---------------------------------------------------------------- 通知身份

function Install-App {
    if (-not ("ShortcutAumid" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

[ComImport, Guid("00021401-0000-0000-C000-000000000046")]
internal class ShellLink { }

[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IShellLinkW
{
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
    void GetIDList(out IntPtr ppidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
    void GetHotkey(out short pwHotkey);
    void SetHotkey(short wHotkey);
    void GetShowCmd(out int piShowCmd);
    void SetShowCmd(int iShowCmd);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
    void Resolve(IntPtr hwnd, uint fFlags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
internal struct PropertyKey { public Guid fmtid; public int pid; }

[StructLayout(LayoutKind.Explicit)]
internal struct PropVariant
{
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pointerValue;
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPropertyStore
{
    void GetCount(out uint cProps);
    void GetAt(uint iProp, out PropertyKey pkey);
    void GetValue(ref PropertyKey key, out PropVariant pv);
    void SetValue(ref PropertyKey key, ref PropVariant pv);
    void Commit();
}

public static class ShortcutAumid
{
    public static void Create(string lnkPath, string target, string arguments, string workingDir, string aumid, string description)
    {
        var link = (IShellLinkW)new ShellLink();
        link.SetPath(target);
        link.SetArguments(arguments);
        link.SetWorkingDirectory(workingDir);
        link.SetDescription(description);
        var store = (IPropertyStore)link;
        var key = new PropertyKey();
        key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        key.pid = 5;
        var pv = new PropVariant();
        pv.vt = 31;
        pv.pointerValue = Marshal.StringToCoTaskMemUni(aumid);
        store.SetValue(ref key, ref pv);
        store.Commit();
        ((IPersistFile)link).Save(lnkPath, true);
    }
}
"@
    }
    $exe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $dir = Split-Path $script:Lnk -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [ShortcutAumid]::Create($script:Lnk, $exe, "-NoProfile -WindowStyle Hidden", $env:USERPROFILE, $script:Aumid, "材料代办录入 · 期限提醒")
    $key = "HKCU:\SOFTWARE\Classes\AppUserModelId\$script:Aumid"
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name "DisplayName" -Value "材料代办录入"
    Set-ItemProperty -Path $key -Name "IconUri" -Value (Join-Path $env:SystemRoot "System32\imageres.dll,-1026")
    Write-Host "已注册通知身份：$script:Aumid"
    Write-Host "  开始菜单快捷方式：$script:Lnk"
}

function Uninstall-App {
    if (Test-Path $script:Lnk) { Remove-Item $script:Lnk -Force; Write-Host "已删除快捷方式：$script:Lnk" }
    $key = "HKCU:\SOFTWARE\Classes\AppUserModelId\$script:Aumid"
    if (Test-Path $key) { Remove-Item $key -Force; Write-Host "已删除注册表项：$key" }
}

# ---------------------------------------------------------------- 清单解析（与 schedule_write.py 同口径）

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
    else {
        $subject = ([string]$item.title).Trim()
        if (-not $subject) { $subject = "事项" }
    }
    return "$(Get-Label $item)｜$subject"
}

# 锚点算法与 schedule_write.py 一致：kind|label|case_no|parties|title|iso(原始 start)
function Get-Anchor($item) {
    $given = ([string]$item.anchor).Trim()
    if ($given) { return $given }
    $kind = ([string]$item.kind).Trim()
    $label = Get-Label $item
    $startText = ""
    if ($item.start) { $startText = (ConvertFrom-AnyTime $item.start).ToString("yyyy-MM-ddTHH:mm:ss") }
    $key = @($kind, $label, [string]$item.case_no, [string]$item.parties, [string]$item.title, $startText) -join "|"
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hex = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key)))).Replace("-", "")
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

function Get-Entries([string]$path) {
    if (-not (Test-Path $path)) { throw "找不到清单文件：$path" }
    $data = Get-Content -Path $path -Encoding UTF8 -Raw | ConvertFrom-Json
    if (-not $data.items) { throw "清单缺少 items 数组" }
    $entries = @()
    foreach ($item in $data.items) {
        if (-not $item.start) { throw "条目缺少 start：$(Get-Title $item)" }
        $start = ConvertFrom-AnyTime $item.start
        $allDay = [bool]$item.all_day
        if ($item.end) { $end = ConvertFrom-AnyTime $item.end }
        elseif ($allDay) { $end = $start.AddHours(23).AddMinutes(59) }
        else { $end = $start.AddHours(2) }
        if ($end -le $start) { $end = $start.AddHours(2) }
        if (([string]$item.kind) -eq "deadline" -and -not $item.deadline_clock) {
            $start = $start.Date.AddHours(9)
            $end = $start.AddMinutes(30)
            $allDay = $false
        }
        $remind = $true
        if ($null -ne $item.remind) { $remind = [bool]$item.remind }
        $entries += [pscustomobject]@{
            Raw    = $item
            Start  = $start
            End    = $end
            AllDay = $allDay
            Anchor = Get-Anchor $item
            Title  = Get-Title $item
            Remind = $remind
        }
    }
    return $entries
}

function Get-TierPlan($entry) {
    if (-not $entry.Remind) { return @() }
    $today = (Get-Date).Date
    $specs = @()
    foreach ($offset in (Get-Offsets $entry.Raw)) {
        if ($offset -eq 0) {
            $fire = $entry.Start.Date.AddHours(7).AddMinutes(30)
            if (-not $entry.AllDay -and $entry.Start.TimeOfDay -le [timespan]::FromHours(7.5)) { $fire = $entry.Start.AddMinutes(-90) }
            $tag = "当天"
        } else {
            $fire = $entry.Start.Date.AddDays(-$offset).AddHours(9)
            $tag = "T-$offset"
        }
        if ($fire.Date -lt $today) { continue }
        $isPast = $fire -le (Get-Date)
        $specs += [pscustomobject]@{
            Offset = $offset
            Anchor = "$($entry.Anchor)-T$offset"
            Title  = "【$tag】$($entry.Title)"
            Fire   = $fire
            Entry  = $entry
            Past   = $isPast
        }
    }
    return $specs
}

# ---------------------------------------------------------------- 通知队列

$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.UI.Notifications.ScheduledToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

function Get-Notifier { return [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:Aumid) }

function Get-MyScheduled {
    return @((Get-Notifier).GetScheduledToastNotifications() | Where-Object { $_.Group -eq $script:Group })
}

function Get-AnchorFromXml([string]$xml) {
    if (-not $xml) { return $null }
    $match = [regex]::Match($xml, "来福ID:\s*([A-Za-z0-9\-]+)")
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Get-TierXml($spec) {
    $item = $spec.Entry.Raw
    $lines = @()
    $subject = (@(([string]$item.case_no).Trim(), ([string]$item.parties).Trim()) | Where-Object { $_ }) -join " "
    if (-not $subject) { $subject = ([string]$item.title).Trim() }
    if ($subject) { $lines += $subject }
    if ($spec.Entry.AllDay) { $lines += "时间：" + $spec.Entry.Start.ToString("yyyy-MM-dd") + "（全天）" }
    else { $lines += "时间：" + $spec.Entry.Start.ToString("yyyy-MM-dd HH:mm") }
    foreach ($pair in @(@("location", "地点"), @("source", "来源"), @("basis", "推算依据"))) {
        $value = ([string]$item.($pair[0])).Trim()
        if ($value) { $lines += "$($pair[1])：$value" }
    }
    $notes = ([string]$item.notes).Trim()
    if ($notes) { $lines += $notes }
    $lines += "来福ID: $($spec.Anchor)"

    $xml = "<toast><visual><binding template=""ToastGeneric""><text>" + (Format-XmlText $spec.Title) + "</text>"
    foreach ($line in $lines) { $xml += "<text>" + (Format-XmlText $line) + "</text>" }
    $xml += "</binding></visual></toast>"
    return $xml
}

function New-TierToast($spec) {
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml((Get-TierXml $spec))
    $toast = New-Object Windows.UI.Notifications.ScheduledToastNotification($doc, [datetimeoffset]::new($spec.Fire))
    # Tag 上限 16 字符：「LR-MI-」缩写为「MI-」
    $toast.Tag = "MI-" + $spec.Anchor.Substring($script:AnchorPrefix.Length)
    $toast.Group = $script:Group
    return $toast
}

function Format-XmlText([string]$text) {
    return ($text -replace "&", "&amp;" -replace "<", "&lt;" -replace ">", "&gt;")
}

function Get-TagFor([string]$anchor) { return "MI-" + $anchor.Substring($script:AnchorPrefix.Length) }

# ---------------------------------------------------------------- 子命令

function Invoke-Doctor {
    Write-Host "材料代办录入 · 系统通知提醒自检"
    Write-Host "  通知身份：$script:Aumid"
    $setting = "$((Get-Notifier).Setting)"
    $registered = Test-Path $script:Lnk
    $pending = (Get-MyScheduled).Count
    Write-Host "  通知开关：$setting"
    Write-Host "  身份注册：$(if ($registered) { '已注册' } else { '未注册（先运行 install）' })"
    Write-Host "  待发提醒：$pending 条"
    $ok = ($setting -eq "Enabled") -and $registered
    Write-Host ""
    if ($ok) { Write-Host "结论：可用。到点由系统通知平台弹出，出现在右下角通知区。" }
    else { Write-Host "结论：尚不可用。未注册先跑 install；开关为 DisabledForUser 时跑 enable-notifications 或到「设置 → 系统 → 通知」打开。" }
    [pscustomobject]@{ ok = $ok; setting = $setting; registered = $registered; pending = $pending } | ConvertTo-Json -Depth 4
}

function Invoke-EnableNotifications {
    $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications"
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name "ToastEnabled" -Value 1 -Type DWord
    Write-Host "已打开通知总开关（ToastEnabled=1）。注意：所有应用的通知都会开始弹出。"
    $svc = Get-Service -Name "WpnUserService_*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($svc) {
        try {
            Restart-Service -Name $svc.Name -Force -ErrorAction Stop
            Write-Host "已重启通知服务：$($svc.Name)"
        } catch {
            Write-Host "通知服务重启失败（$($_.Exception.Message)），注销后重新登录即可生效。"
        }
    }
    Write-Host "复查：$((Get-Notifier).Setting)"
}

function Invoke-Plan([bool]$dryRun) {
    if (-not $Json) { throw "缺少 -Json 参数" }
    $specs = @()
    foreach ($entry in (Get-Entries $Json)) { $specs += (Get-TierPlan $entry) }
    $existing = Get-MyScheduled
    $existingTags = @($existing | ForEach-Object { $_.Tag })

    $due = @($specs | Where-Object { -not $_.Past })
    $skipped = @($specs | Where-Object { $_.Past })
    Write-Host "$(if ($dryRun) { '预演' } else { '执行' })：待排定 $($due.Count) 条，跳过 $($skipped.Count) 条（时点已过）"
    foreach ($spec in $specs) {
        $tag = Get-TagFor $spec.Anchor
        $action = "新建"
        if ($existingTags -contains $tag) { $action = "更新" }
        if ($spec.Past) { $action = "跳过" }
        Write-Host ("  [{0}] {1}　{2}　{3}" -f $spec.Anchor, $action, $spec.Fire.ToString("yyyy-MM-dd HH:mm"), $spec.Title)
    }
    if ($dryRun) {
        Write-Host ""
        Write-Host "预演结束（未排定）。确认后加 -Apply。"
        [pscustomobject]@{ applied = $false; count = $due.Count; skipped = $skipped.Count } | ConvertTo-Json -Depth 4
        return
    }
    $notifier = Get-Notifier
    $created = 0
    $replaced = 0
    foreach ($spec in $due) {
        $tag = Get-TagFor $spec.Anchor
        $old = @($existing | Where-Object { $_.Tag -eq $tag })
        if ($old.Count -gt 0) {
            foreach ($row in $old) { $notifier.RemoveFromSchedule($row) }
            $replaced++
        } else {
            $created++
        }
        $notifier.AddToSchedule((New-TierToast $spec))
    }
    if ($skipped.Count -gt 0) { Write-Host "跳过 $($skipped.Count) 条（档位时点已过，日历条目仍在）。" }
    Write-Host "完成：新建 $created 条，替换 $replaced 条；当前待发 $((Get-MyScheduled).Count) 条。"
    [pscustomobject]@{ applied = $true; created = $created; replaced = $replaced; skipped = $skipped.Count; pending = (Get-MyScheduled).Count } | ConvertTo-Json -Depth 4
}

function Invoke-List {
    $items = Get-MyScheduled
    Write-Host "待发提醒：$($items.Count) 条"
    foreach ($row in ($items | Sort-Object { $_.DeliveryTime })) {
        Write-Host ("  [{0}] {1}　{2}" -f (Get-AnchorFromXml $row.Content.GetXml()), $row.DeliveryTime.ToString("yyyy-MM-dd HH:mm"), $row.Tag)
    }
    [pscustomobject]@{ count = $items.Count; anchors = @($items | ForEach-Object { Get-AnchorFromXml $_.Content.GetXml() }) } | ConvertTo-Json -Depth 4
}

# 安装后自检：用与正式提醒完全相同的构造路径排一条通知，确认能真正弹出
# 立即预览：把清单里最近一条未过期的档位当场弹出来（只发预览，不改动已排定的提醒）
function Invoke-Preview {
    if (-not $Json) { throw "缺少 -Json 参数" }
    $specs = @()
    foreach ($entry in (Get-Entries $Json)) { $specs += (Get-TierPlan $entry) }
    $due = @($specs | Where-Object { -not $_.Past } | Sort-Object { $_.Fire })
    if ($due.Count -eq 0) { throw "清单里没有可提醒的档位（可能都已过期）" }
    $spec = $due[0]
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml((Get-TierXml $spec))
    $toast = New-Object Windows.UI.Notifications.ToastNotification($doc)
    $toast.Tag = "MI-" + $spec.Anchor.Substring($script:AnchorPrefix.Length)
    $toast.Group = $script:Group
    (Get-Notifier).Show($toast)
    Write-Host "已发出预览通知：$($spec.Title)"
    Write-Host "  对应档位：$($spec.Anchor)（正式弹出时间 $($spec.Fire.ToString('yyyy-MM-dd HH:mm'))）"
    [pscustomobject]@{ sent = $true; anchor = $spec.Anchor; fire = $spec.Fire.ToString("yyyy-MM-dd HH:mm") } | ConvertTo-Json -Depth 4
}

function Invoke-SelfTest {
    $fire = (Get-Date).AddSeconds($DelaySeconds)
    $raw = [pscustomobject]@{
        kind    = "task"
        title   = "提醒投递自检"
        notes   = "自检条目，可忽略；用 clear -Anchor LR-MI-SELFTEST -Apply 清除"
    }
    $entry = [pscustomobject]@{
        Raw    = $raw
        Start  = $fire
        End    = $fire.AddMinutes(15)
        AllDay = $false
        Anchor = "LR-MI-SELFTEST"
        Title  = "待办｜提醒投递自检"
        Remind = $true
    }
    $spec = [pscustomobject]@{
        Offset = 0
        Anchor = "LR-MI-SELFTEST-T0"
        Title  = "【自检】材料代办录入 · 提醒投递"
        Fire   = $fire
        Entry  = $entry
        Past   = $false
    }
    $notifier = Get-Notifier
    foreach ($row in @($notifier.GetScheduledToastNotifications() | Where-Object { $_.Tag -eq (Get-TagFor $spec.Anchor) })) {
        $notifier.RemoveFromSchedule($row)
    }
    $notifier.AddToSchedule((New-TierToast $spec))
    Write-Host "已排定自检通知：$($fire.ToString('yyyy-MM-dd HH:mm:ss'))（约 $DelaySeconds 秒后弹出）"
    Write-Host "若到点未弹出，先看 doctor 的通知开关是否为 Enabled。"
    [pscustomobject]@{ scheduled = $fire.ToString("yyyy-MM-dd HH:mm:ss"); anchor = $spec.Anchor } | ConvertTo-Json -Depth 4
}

function Invoke-Clear {
    if (-not $Anchor -and -not $Prefix) { throw "需指定 -Anchor 或 -Prefix" }
    if ($Anchor -and -not ($Anchor -match '^[A-Za-z0-9\-]+$')) { throw "锚点格式不正确：$Anchor" }
    $targets = @()
    foreach ($row in (Get-MyScheduled)) {
        $a = Get-AnchorFromXml $row.Content.GetXml()
        if (-not $a) { continue }
        if ($Anchor) {
            if ($a -eq $Anchor -or $a.StartsWith("$Anchor-T")) { $targets += [pscustomobject]@{ Anchor = $a; Row = $row } }
        } elseif ($a.StartsWith($Prefix)) {
            $targets += [pscustomobject]@{ Anchor = $a; Row = $row }
        }
    }
    if (-not $targets) {
        Write-Host "未找到匹配的待发提醒。"
        [pscustomobject]@{ applied = $false; deleted = 0 } | ConvertTo-Json -Depth 4
        return
    }
    Write-Host "命中 $($targets.Count) 条："
    foreach ($row in $targets) {
        Write-Host ("  [{0}] {1}" -f $row.Anchor, $row.Row.DeliveryTime.ToString("yyyy-MM-dd HH:mm"))
    }
    if (-not $Apply) {
        Write-Host ""
        Write-Host "预演（未取消，加 -Apply 执行）"
        [pscustomobject]@{ applied = $false; planned = $targets.Count } | ConvertTo-Json -Depth 4
        return
    }
    $notifier = Get-Notifier
    foreach ($row in $targets) { $notifier.RemoveFromSchedule($row.Row) }
    Write-Host "已取消 $($targets.Count) 条待发提醒。"
    [pscustomobject]@{ applied = $true; deleted = $targets.Count } | ConvertTo-Json -Depth 4
}

switch ($Command) {
    "doctor" { Invoke-Doctor }
    "install" { Install-App }
    "uninstall" { Uninstall-App }
    "enable-notifications" { Invoke-EnableNotifications }
    "plan" { Invoke-Plan $true }
    "apply" { Invoke-Plan $false }
    "list" { Invoke-List }
    "clear" { Invoke-Clear }
    "selftest" { Invoke-SelfTest }
    "preview" { Invoke-Preview }
}
