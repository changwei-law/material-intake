# 材料代办录入 · 钉钉提醒（自定义机器人 webhook，本地增补）
#
# 作用：把日程清单的各档位注册成 Windows 计划任务，到点由本机向钉钉自定义机器人
#       推送一条消息，手机钉钉即收到提醒。不需要企业管理员，不需要公网地址。
#
# 用法：
#   powershell -File dingtalk_remind.ps1 config -Webhook "https://oapi.dingtalk.com/robot/send?access_token=xxx" [-Secret "SECxxx"]
#   powershell -File dingtalk_remind.ps1 test
#   powershell -File dingtalk_remind.ps1 plan  -Json 产出\日程清单.json
#   powershell -File dingtalk_remind.ps1 apply -Json 产出\日程清单.json
#   powershell -File dingtalk_remind.ps1 list
#   powershell -File dingtalk_remind.ps1 clear -Anchor LR-MI-XXXXXXXX -Apply
#   powershell -File dingtalk_remind.ps1 send  -Anchor LR-MI-XXXXXXXX-T1     # 由计划任务调用

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("config", "test", "plan", "apply", "list", "clear", "send")]
    [string]$Command,
    [string]$Json,
    [string]$Webhook,
    [string]$Secret,
    [string]$Anchor,
    [string]$Prefix = "LR-MI-",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

$script:ConfigDir = Join-Path $env:USERPROFILE ".material-intake"
$script:ConfigFile = Join-Path $script:ConfigDir "dingtalk.json"
$script:PayloadDir = Join-Path $script:ConfigDir "dingtalk-reminders"
$script:TaskPrefix = "材料代办录入-钉钉提醒-"
$script:AnchorPrefix = "LR-MI-"
$script:Self = $MyInvocation.MyCommand.Path
$script:KindLabel = @{ hearing = "开庭"; deadline = "期限"; meeting = "会议"; task = "待办"; onsite = "驻场" }
$script:DefaultOffsets = @{
    hearing  = @(7, 3, 1, 0)
    deadline = @(7, 3, 1, 0)
    onsite   = @(7, 3, 1, 0)
    meeting  = @(1, 0)
    task     = @(0)
}

function Get-Config {
    if (-not (Test-Path $script:ConfigFile)) { throw "尚未配置钉钉机器人，先跑 config -Webhook <地址>" }
    return (Get-Content $script:ConfigFile -Encoding UTF8 -Raw | ConvertFrom-Json)
}

function Save-Config([string]$url, [string]$sec) {
    if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null }
    $obj = [pscustomobject]@{ webhook = $url; secret = $sec; updated = (Get-Date).ToString("yyyy-MM-dd HH:mm") }
    [System.IO.File]::WriteAllText($script:ConfigFile, ($obj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已保存钉钉机器人配置：$script:ConfigFile"
}

function Send-DingTalk([string]$title, [string]$text) {
    $cfg = Get-Config
    $url = [string]$cfg.webhook
    if ($cfg.secret) {
        $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $stringToSign = "$ts`n$($cfg.secret)"
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes([string]$cfg.secret)
        $sign = [System.Uri]::EscapeDataString([Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign))))
        $sep = "?"
        if ($url -like "*?*") { $sep = "&" }
        $url = "$url$sep" + "timestamp=$ts&sign=$sign"
    }
    $body = @{ msgtype = "markdown"; markdown = @{ title = $title; text = $text } } | ConvertTo-Json -Depth 5
    $resp = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30
    return $resp
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
    throw "时间格式无法解析：$text"
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

function Get-Anchor($item) {
    $given = ([string]$item.anchor).Trim()
    if ($given) { return $given }
    $startText = ""
    if ($item.start) { $startText = (ConvertFrom-AnyTime $item.start).ToString("yyyy-MM-ddTHH:mm:ss") }
    $key = @(([string]$item.kind).Trim(), (Get-Label $item), [string]$item.case_no, [string]$item.parties, [string]$item.title, $startText) -join "|"
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hex = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key)))).Replace("-", "")
    return $script:AnchorPrefix + $hex.Substring(0, 8).ToUpper()
}

function Get-Offsets($item) {
    $names = @($item.PSObject.Properties.Name)
    $raw = $null
    $given = $false
    foreach ($key in @("offsets", "remind_offsets", "reminders")) {
        if ($names -contains $key) { $raw = $item.$key; $given = $true; break }
    }
    if (-not $given) {
        $kind = if ($item.kind) { [string]$item.kind } else { "task" }
        if ($script:DefaultOffsets.ContainsKey($kind)) { $raw = $script:DefaultOffsets[$kind] } else { $raw = @(0) }
    }
    $values = @()
    if ($null -ne $raw) { foreach ($value in $raw) { $values += [int]$value } }
    return @($values | Sort-Object -Descending -Unique)
}

function Get-TierPlan([string]$path) {
    if (-not (Test-Path $path)) { throw "找不到清单文件：$path" }
    $data = Get-Content -Path $path -Encoding UTF8 -Raw | ConvertFrom-Json
    if (-not $data.items) { throw "清单缺少 items 数组" }
    $today = (Get-Date).Date
    $specs = @()
    foreach ($item in $data.items) {
        if (-not $item.start) { throw "条目缺少 start：$(Get-Title $item)" }
        $start = ConvertFrom-AnyTime $item.start
        $allDay = [bool]$item.all_day
        if (([string]$item.kind) -eq "deadline" -and -not $item.deadline_clock) { $start = $start.Date.AddHours(9); $allDay = $false }
        $anchor = Get-Anchor $item
        $title = Get-Title $item
        $lines = @()
        $subject = (@(([string]$item.case_no).Trim(), ([string]$item.parties).Trim()) | Where-Object { $_ }) -join " "
        if ($subject) { $lines += "**$subject**" }
        if ($allDay) { $lines += "时间：" + $start.ToString("yyyy-MM-dd") + "（全天）" }
        else { $lines += "时间：" + $start.ToString("yyyy-MM-dd HH:mm") }
        foreach ($pair in @(@("location", "地点"), @("source", "来源"), @("basis", "推算依据"))) {
            $value = ([string]$item.($pair[0])).Trim()
            if ($value) { $lines += "$($pair[1])：$value" }
        }
        $notes = ([string]$item.notes).Trim()
        if ($notes) { $lines += $notes }
        $lines += "来福ID: $anchor"
        foreach ($offset in (Get-Offsets $item)) {
            if ($offset -eq 0) {
                $fire = $start.Date.AddHours(7).AddMinutes(30)
                if (-not $allDay -and $start.TimeOfDay -le [timespan]::FromHours(7.5)) { $fire = $start.AddMinutes(-90) }
                $tag = "当天"
            } else {
                $fire = $start.Date.AddDays(-$offset).AddHours(9)
                $tag = "T-$offset"
            }
            if ($fire.Date -lt $today) { continue }
            $specs += [pscustomobject]@{
                Anchor = "$anchor-T$offset"
                Title  = "【$tag】$title"
                Fire   = $fire
                Body   = (($lines -join "  `n") -replace "  ", "")
                Past   = ($fire -le (Get-Date))
            }
        }
    }
    return $specs
}

# ---------------------------------------------------------------- 子命令

function Invoke-Config {
    if (-not $Webhook) { throw "缺少 -Webhook" }
    Save-Config $Webhook $Secret
}

function Invoke-Test {
    $cfg = Get-Config
    "机器人：$($cfg.webhook.Substring(0, [Math]::Min(60, $cfg.webhook.Length)))..."
    "加签：$(if ($cfg.secret) { '已配置' } else { '未配置' })"
    $r = Send-DingTalk "材料代办录入 · 提醒通道测试" "### 材料代办录入 · 提醒通道测试`n看到这条，说明钉钉提醒通道已打通。`n`n来福ID: LR-MI-DINGTEST"
    "钉钉返回：" + ($r | ConvertTo-Json -Compress)
}

function Invoke-Plan([bool]$dryRun) {
    if (-not $Json) { throw "缺少 -Json 参数" }
    $specs = Get-TierPlan $Json
    $due = @($specs | Where-Object { -not $_.Past })
    $skipped = @($specs | Where-Object { $_.Past })
    Write-Host "$(if ($dryRun) { '预演' } else { '执行' })：待排定 $($due.Count) 条，跳过 $($skipped.Count) 条（时点已过）"
    foreach ($spec in $specs) {
        $action = "新建"
        if ($spec.Past) { $action = "跳过" }
        Write-Host ("  [{0}] {1}　{2}　{3}" -f $spec.Anchor, $action, $spec.Fire.ToString("yyyy-MM-dd HH:mm"), $spec.Title)
    }
    if ($dryRun) { return }

    if (-not (Test-Path $script:PayloadDir)) { New-Item -ItemType Directory -Force -Path $script:PayloadDir | Out-Null }
    $created = 0
    foreach ($spec in $due) {
        $taskName = $script:TaskPrefix + $spec.Anchor
        $payloadFile = Join-Path $script:PayloadDir ($spec.Anchor + ".json")
        $payload = [pscustomobject]@{ anchor = $spec.Anchor; title = $spec.Title; fire = $spec.Fire.ToString("yyyy-MM-ddTHH:mm:ss"); body = $spec.Body }
        [System.IO.File]::WriteAllText($payloadFile, ($payload | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" send -Anchor {1}' -f $script:Self, $spec.Anchor)
        $trigger = New-ScheduledTaskTrigger -Once -At $spec.Fire
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "材料代办录入：钉钉提醒 $($spec.Title)" -Force | Out-Null
        $created++
    }
    Write-Host "完成：已注册 $created 个到点任务；跳过 $($skipped.Count) 条。"
}

function Invoke-List {
    $tasks = Get-ScheduledTask -TaskName ($script:TaskPrefix + "*") -ErrorAction SilentlyContinue
    Write-Host "已注册钉钉提醒任务：$($tasks.Count) 个"
    foreach ($task in $tasks) {
        $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -ErrorAction SilentlyContinue
        $anchor = $task.TaskName.Substring($script:TaskPrefix.Length)
        Write-Host ("  [{0}] 下次触发：{1}" -f $anchor, $info.NextRunTime)
    }
}

function Invoke-Clear {
    if (-not $Anchor) { throw "需指定 -Anchor" }
    $names = @()
    if ($Anchor -like "*-T*") { $names += ($script:TaskPrefix + $Anchor) }
    else {
        foreach ($suffix in @("T0", "T1", "T3", "T7", "T14", "T30")) { $names += ($script:TaskPrefix + "$Anchor-$suffix") }
    }
    $hit = @()
    foreach ($name in $names) { if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { $hit += $name } }
    if (-not $hit) { Write-Host "未找到匹配任务。"; return }
    Write-Host "命中 $($hit.Count) 个："; $hit | ForEach-Object { Write-Host "  $_" }
    if (-not $Apply) { Write-Host "预演（未删除，加 -Apply 执行）"; return }
    foreach ($name in $hit) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        $anchorName = $name.Substring($script:TaskPrefix.Length)
        Remove-Item -LiteralPath (Join-Path $script:PayloadDir ($anchorName + ".json")) -Force -ErrorAction SilentlyContinue
    }
    Write-Host "已删除 $($hit.Count) 个任务。"
}

function Invoke-Send {
    if (-not $Anchor) { throw "缺少 -Anchor" }
    $payloadFile = Join-Path $script:PayloadDir ($Anchor + ".json")
    if (-not (Test-Path $payloadFile)) { throw "找不到提醒内容：$payloadFile" }
    $payload = Get-Content $payloadFile -Encoding UTF8 -Raw | ConvertFrom-Json
    $r = Send-DingTalk $payload.title $payload.body
    Write-Host ("已推送：{0} → {1}" -f $payload.title, ($r | ConvertTo-Json -Compress))
}

switch ($Command) {
    "config" { Invoke-Config }
    "test" { Invoke-Test }
    "plan" { Invoke-Plan $true }
    "apply" { Invoke-Plan $false }
    "list" { Invoke-List }
    "clear" { Invoke-Clear }
    "send" { Invoke-Send }
}
