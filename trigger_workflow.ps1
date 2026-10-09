# 触发 zotero-arxiv-daily 的 GitHub Actions workflow
#
# 背景：GitHub 禁用 fork 仓库的 schedule（cron）定时任务。用 Windows 计划任务
#      在外部调 GitHub API，通过 repository_dispatch 事件触发。
#
# 触发源（由setup_scheduler.ps1 注册）：
#   - 开机 / 登录      → 延迟 StartDelayMinutes 分钟后再跑，等代理软件就绪
#   - 周一/周四 10:00   → 覆盖「整周不关机」的情况（不会触发开机事件）
#   - 周一/周四 10:00–23:00 每 30 分钟 → 网络失败时的重试
#
# 去重：记录「已推送的日期」，同一天无论触发多少次只发一封。
#       漏掉的计划日不补推（补推只能拿到最新论文，补不回丢失的那批）。
#
# 用法：
#   .\trigger_workflow.ps1              按计划逻辑触发（计划任务调用）
#   .\trigger_workflow.ps1 -Force       无条件触发（手动测试）
#   .\trigger_workflow.ps1 -Probe       只探测网络，不推送（重试时避免重复提交）
#   .\trigger_workflow.ps1 -KeepAlive   触发 Keep Alive（防仓库 60 天无活动）

param(
    [switch]$KeepAlive,
    [switch]$Force,
    [switch]$Probe,
    [int]$StartDelayMinutes = 0
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

# ------------------------------------------------------- 开机延迟
# 开机瞬间网络栈尚未就绪，代理软件也需要时间启动。
# 延迟后再执行，避免必然失败的第一次尝试。
if ($StartDelayMinutes -gt 0) {
    Write-Output "[$(Get-Date -Format 'HH:mm:ss')] 等待 $StartDelayMinutes 分钟后执行（等待网络/代理就绪）..."
    Start-Sleep -Seconds ($StartDelayMinutes * 60)
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

        $stampFile = Join-Path $scriptDir '.last_push_date.txt'
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
    # 只验证网络与凭据，不真正触发。用于重试循环里区分
    # 「网络还没通」与「已经推过了」，避免重复提交。
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
    # 401 = token 失效或过期，这是需要人工处理的问题，单独标注
    if ($msg -match '401') {
        Write-Log "触发失败：GitHub Token 无效或已过期（401）。需在 https://github.com/settings/tokens 新建 token 并更新 github_token.txt —— $msg" -IsError
    }
    else {
        Write-Log "触发失败（网络不可达或 GitHub 暂时异常，将由后续重试自动补上）—— $msg" -IsError
    }
    exit 1
}
