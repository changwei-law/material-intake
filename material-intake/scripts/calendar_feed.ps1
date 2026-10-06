# 材料代办录入 · 本机日历订阅（Windows 本地增补）
#
# 作用：把工作区里各任务的 产出\日程清单.ics 合并成一个 agenda.ics，用
#       http://127.0.0.1:8799/agenda.ics 提供给桌面日历客户端（如 Thunderbird）订阅。
#       日程更新后重新 publish，客户端按自己的刷新周期自动拉取。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File calendar_feed.ps1 status
#   powershell -ExecutionPolicy Bypass -File calendar_feed.ps1 publish -Root "<任务根目录>"
#   powershell -ExecutionPolicy Bypass -File calendar_feed.ps1 start
#   powershell -ExecutionPolicy Bypass -File calendar_feed.ps1 stop
#   powershell -ExecutionPolicy Bypass -File calendar_feed.ps1 install -Root "<任务根目录>"   # 开机自启（计划任务）
#   powershell -ExecutionPolicy Bypass -File calendar_feed.ps1 uninstall
#
# 可选参数：-Port 8799、-FeedDir "<订阅输出目录>"、-Python "<python.exe 路径>"
#
# 注意：install 会注册一个开机自启的计划任务，并常驻一个只监听 127.0.0.1 的本地 HTTP 服务；
#       uninstall 可整条撤掉（删任务 + 停服务）。

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("status", "publish", "start", "stop", "install", "uninstall")]
    [string]$Command,
    [string]$Root,
    [string]$FeedDir,
    [string]$Python,
    [int]$Port = 8799
)

$ErrorActionPreference = "Stop"

# 路径全部按现场推导，不写死机器路径：
#   技能目录 = 本脚本所在 scripts 目录的上一级；
#   Python 解析顺序：-Python 指定 → PATH 里的 python／python3／py（须通过可用性校验）
#                   → 本机 Codex 自带运行时 → 失败即报错；
#   订阅目录默认放用户目录下；任务根（去哪里找 产出\日程清单.ics）用 -Root 给出。
$script:SkillDir = Split-Path -Parent $PSScriptRoot
$script:Server = Join-Path $script:SkillDir "scripts\serve_feed.py"

function Test-PythonUsable([string]$path) {
    # Windows 商店会放一个占位 python.exe（WindowsApps 下），能通过 Get-Command 与 Test-Path，
    # 但跑起来立刻退出——必须真正执行一次才算数，否则会把无效路径写进开机自启任务。
    if (-not $path) { return $false }
    if (-not (Test-Path $path)) { return $false }
    if ($path -like "*\WindowsApps\*") { return $false }
    try {
        $probe = & $path -c "import sys; print(sys.version_info[0])" 2>$null
        return ($LASTEXITCODE -eq 0 -and ("$probe").Trim() -eq "3")
    } catch {
        return $false
    }
}

function Resolve-Python {
    $candidates = @()
    if ($Python) { $candidates += $Python }
    foreach ($name in @("python", "python3", "py")) {
        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($found -and $found.Source) { $candidates += $found.Source }
    }
    $candidates += (Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe")
    foreach ($candidate in $candidates) {
        if (Test-PythonUsable $candidate) { return $candidate }
    }
    return $null
}

$script:Python = Resolve-Python
if (-not $FeedDir) { $FeedDir = Join-Path $env:USERPROFILE ".material-intake\calendar-feed" }
$script:FeedDir = $FeedDir
$script:TaskName = "材料代办录入-日历订阅"
$script:DefaultRoot = $Root

function Assert-Python {
    if ($script:Python) { return }
    throw ("找不到可用的 Python。请用 -Python <python.exe 路径> 指定一个真解释器" +
           "（Windows 商店的占位 python.exe 不算，本机 Codex 自带运行时在 " +
           "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe）。")
}

function Invoke-Serve {
    Assert-Python
    if (-not (Test-Path $script:Server)) { throw "找不到服务脚本：$($script:Server)" }
    Start-Process -FilePath $script:Python -ArgumentList @($script:Server, $script:FeedDir, $Port) -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if (Test-Serve) {
        Write-Host "已启动日历订阅服务：http://127.0.0.1:$Port/（解释器：$($script:Python)）"
    } else {
        throw "服务未能启动：进程已拉起但端口 $Port 无响应。请检查解释器是否可用（当前：$($script:Python)），或用 -Python 指定真解释器后重试。"
    }
}

function Stop-Serve {
    $killed = 0
    Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.CommandLine -and $_.CommandLine -like "*serve_feed.py*") {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $killed++
        }
    }
    Write-Host "已停止日历订阅服务：$killed 个进程"
}

function Test-Serve {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect("127.0.0.1", $Port)
        $client.Close()
        return $true
    } catch { return $false }
}

function Invoke-Publish {
    $source = if ($Root) { $Root } else { $script:DefaultRoot }
    if (-not $source) { throw "请用 -Root 指定任务根目录（其下各任务的 产出\日程清单.ics 会被合并）" }
    if (-not (Test-Path $source)) { throw "找不到来源目录：$source" }
    if (-not (Test-Path $script:FeedDir)) { New-Item -ItemType Directory -Force -Path $script:FeedDir | Out-Null }

    $files = Get-ChildItem -Path $source -Recurse -File -Filter "*.ics" -ErrorAction SilentlyContinue
    $events = @()
    $timezones = @()
    foreach ($file in $files) {
        $text = Get-Content -Path $file.FullName -Encoding UTF8 -Raw
        $text = $text -replace "`r`n", "`n"
        foreach ($m in [regex]::Matches($text, "(?s)BEGIN:VEVENT.*?END:VEVENT")) {
            $events += ($m.Value -replace "`n", "`r`n")
        }
        foreach ($m in [regex]::Matches($text, "(?s)BEGIN:VTIMEZONE.*?END:VTIMEZONE")) {
            $block = $m.Value
            if (-not ($timezones | Where-Object { $_ -eq $block })) { $timezones += ($block -replace "`n", "`r`n") }
        }
    }
    if ($events.Count -eq 0) { throw "来源目录里没有找到任何 .ics 事件：$source" }

    $lines = @("BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Material Intake//Local Feed//CN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "X-WR-CALNAME:材料代办录入")
    $lines += $timezones
    $lines += $events
    $lines += "END:VCALENDAR"
    $target = Join-Path $script:FeedDir "agenda.ics"
    [System.IO.File]::WriteAllText($target, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("已生成订阅文件：{0}（来源 {1} 个 .ics 文件，合并 {2} 个事件）" -f $target, $files.Count, $events.Count)
    Write-Host ("订阅地址：http://127.0.0.1:{0}/agenda.ics" -f $Port)
}

function Invoke-Status {
    Write-Host "材料代办录入 · 本机日历订阅自检"
    Write-Host "  订阅目录：$script:FeedDir"
    Write-Host "  解释器  ：$(if ($script:Python) { $script:Python } else { '未找到可用的 Python（-Python 指定一个真解释器）' })"
    $agenda = Join-Path $script:FeedDir "agenda.ics"
    Write-Host "  订阅文件：$(if (Test-Path $agenda) { '存在（' + [math]::Round((Get-Item $agenda).Length/1KB,1) + ' KB，' + (Get-Item $agenda).LastWriteTime.ToString('yyyy-MM-dd HH:mm') + '）' } else { '未生成，先跑 publish' })"
    $running = Test-Serve
    Write-Host "  服务状态：$(if ($running) { "运行中（127.0.0.1:$Port）" } else { "未运行" })"
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($task) { Write-Host "  开机自启：已注册（状态 $($task.State)）" } else { Write-Host "  开机自启：未注册（install 可注册）" }
    if ($running) {
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/agenda.ics" -UseBasicParsing -TimeoutSec 10
            Write-Host "  订阅可用：HTTP $($resp.StatusCode)，$($resp.RawContentLength) 字节，Content-Type=$($resp.Headers['Content-Type'])"
        } catch {
            Write-Host "  订阅取用失败：$($_.Exception.Message)"
        }
    }
}

function Install-Feed {
    Assert-Python    # Python 不可用就中止，避免把无效路径写进计划任务
    if (-not (Test-Path $script:FeedDir)) { New-Item -ItemType Directory -Force -Path $script:FeedDir | Out-Null }
    Stop-Serve
    Invoke-Serve
    $action = New-ScheduledTaskAction -Execute $script:Python -Argument ('"{0}" "{1}" {2}' -f $script:Server, $script:FeedDir, $Port)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Settings $settings -Description "把本机日历订阅（agenda.ics）提供给桌面日历客户端" -Force | Out-Null
    Write-Host "已注册开机自启计划任务：$($script:TaskName)"
}

function Uninstall-Feed {
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false; Write-Host "已删除计划任务：$($script:TaskName)" }
    Stop-Serve
}

switch ($Command) {
    "status" { Invoke-Status }
    "publish" { Invoke-Publish }
    "start" { Invoke-Serve }
    "stop" { Stop-Serve }
    "install" { Install-Feed }
    "uninstall" { Uninstall-Feed }
}
