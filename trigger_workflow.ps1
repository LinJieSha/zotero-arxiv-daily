# 触发 zotero-arxiv-daily 的 GitHub Actions workflow
#
# 背景：GitHub 禁用 fork 仓库的 schedule（cron）定时任务。用 Windows 计划任务
#      在外部调 GitHub API，通过 repository_dispatch 事件触发。
#
# 触发源（由 setup_scheduler.ps1 注册）：
#   - 开机 / 登录      → 由计划任务延迟 3 分钟后执行，等代理软件就绪
#   - 周一/周四 10:00   → 覆盖「整周不关机」的情况（不会触发开机事件）
#
# 去重：记录「已推送的日期」，同一天无论触发多少次只发一封。
#       漏掉的计划日不补推（补推只能拿到最新论文，补不回丢失的那批）。
#
# 失败重试：没有定时重试。若推送因网络失败，当天的开机/登录触发
#       会自然补上（去重标记只在成功时写入）；若当天再无开关机，
#       则需手动执行本脚本 —— 失败会记入 .trigger_failures.log。
#
# 用法：
#   .\trigger_workflow.ps1              按计划逻辑触发（计划任务调用）
#   .\trigger_workflow.ps1 -Force       无条件触发（手动测试）
#   .\trigger_workflow.ps1 -Probe       只探测网络，不推送（仅供人工诊断）
#   .\trigger_workflow.ps1 -KeepAlive   触发 Keep Alive（防仓库 60 天无活动）

param(
    [switch]$KeepAlive,
    [switch]$Force,
    [switch]$Probe
)

$ErrorActionPreference = 'Stop'

$scriptDir  = $PSScriptRoot
$markerFile = Join-Path $scriptDir '.last_push_date.txt'
$failLog    = Join-Path $scriptDir '.trigger_failures.log'

function Write-Log {
    param([string]$Message, [switch]$IsError)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ($IsError) {
        # 失败才落盘。成功/跳过不记，避免日志膨胀。
        # 只保留最近 200 条。
        Add-Content -Path $failLog -Value "[$ts] $Message" -Encoding UTF8
        $all = Get-Content $failLog -Encoding UTF8
        if ($all.Count -gt 200) {
            $all | Select-Object -Last 200 | Set-Content $failLog -Encoding UTF8
        }
    }
    Write-Output "[$ts] $Message"
}

# ---------------------------------------------------------------- Token
$tokenFile = Join-Path $scriptDir 'github_token.txt'
if (-not (Test-Path $tokenFile)) {
    Write-Log "找不到 token 文件：$tokenFile" -IsError
    exit 1
}
$token = (Get-Content $tokenFile -Raw).Trim()
if ($token -notmatch '^ghp_') {
    Write-Log 'github_token.txt 内容无效，应为以 ghp_ 开头的 GitHub Token' -IsError
    exit 1
}

# ------------------------------------------------------- 去重判断
if ($KeepAlive) {
    # Keep Alive 靠 commit 防止仓库 60 天无活动被停用，30 天一次足够。
    # 开机很频繁，必须限流，否则每次开机都提交一次。
    $keepStamp = Join-Path $scriptDir '.last_keepalive_date.txt'
    if (-not $Force -and (Test-Path $keepStamp)) {
        $raw = (Get-Content $keepStamp -Raw).Trim()
        $last = [datetime]::MinValue
        if ([datetime]::TryParse($raw, [ref]$last)) {
            $days = ((Get-Date) - $last).Days
            if ($days -lt 30) {
                Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] Keep Alive 距上次仅 $days 天（<30），跳过。"
                exit 0
            }
        }
    }
    $eventType = 'keep-alive'
}
else {
    if (-not $Force) {
        $today = (Get-Date).Date

        if ($today.DayOfWeek -ne 'Monday' -and $today.DayOfWeek -ne 'Thursday') {
            Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] 今天不是计划日（周一/周四），跳过。"
            exit 0
        }

        $stampFile = $markerFile
        if (Test-Path $stampFile) {
            $raw = (Get-Content $stampFile -Raw).Trim()
            if ($raw -eq $today.ToString('yyyy-MM-dd')) {
                Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] 今天已推送过，跳过。"
                exit 0
            }
        }
    }
    $eventType = 'scheduled-run'
}

# ---------------------------------------------------------------- 触发
$uri = 'https://api.github.com/repos/LinJieSha/zotero-arxiv-daily/dispatches'
$body = @{ event_type = $eventType } | ConvertTo-Json

if ($Probe) {
    # ⚠️ 仅用于人工诊断。探测成功后直接退出，不会触发任何 workflow。
    #    切勿把 -Probe 接到计划任务的触发器上 —— 那样推送会静默失效。
    try {
        Invoke-WebRequest -Uri 'https://api.github.com/rate_limit' `
            -Headers @{ Authorization = "Bearer $token"; 'User-Agent' = 'zotero-daily-trigger' } `
            -TimeoutSec 20 -UseBasicParsing | Out-Null
        Write-Log '网络探测：正常'
        exit 0
    }
    catch {
        Write-Log "网络探测失败：$($_.Exception.Message)" -IsError
        exit 2
    }
}

try {
    Invoke-RestMethod -Uri $uri -Method POST `
        -Headers @{
            Authorization = "Bearer $token"
            Accept        = 'application/vnd.github+json'
            'User-Agent'  = 'zotero-daily-trigger'
        } `
        -ContentType 'application/json' `
        -Body $body | Out-Null

    $label = if ($KeepAlive) { 'Keep Alive' } else { '论文推送' }
    Write-Log "已触发 $label（event_type=$eventType）"

    if (-not $KeepAlive) {
        Set-Content -Path $markerFile -Value (Get-Date -Format 'yyyy-MM-dd') -Encoding ASCII -NoNewline
    }
    else {
        Set-Content -Path (Join-Path $scriptDir '.last_keepalive_date.txt') `
                    -Value (Get-Date -Format 'yyyy-MM-dd') -Encoding ASCII -NoNewline
    }
    exit 0
}
catch {
    $msg = $_.Exception.Message
    # 取真实的 HTTP 状态码，而不是在错误消息里搜 "401"。
    # 端口号、超时秒数都可能含 401，字符串匹配会误判并误导排查方向。
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    # 401 = token 失效或过期，这是唯一需要人工处理的问题，单独标注
    if ($status -eq 401) {
        Write-Log "触发失败：GitHub Token 无效或已过期（HTTP 401）。需在 https://github.com/settings/tokens 新建 token 并更新 github_token.txt" -IsError
    }
    else {
        Write-Log "触发失败（网络不可达或 GitHub 暂时异常）—— $msg" -IsError
    }
    exit 1
}
