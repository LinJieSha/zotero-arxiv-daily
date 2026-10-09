# 触发 zotero-arxiv-daily 的 GitHub Actions workflow
#
# 背景：GitHub 禁用 fork 仓库的 schedule（cron）定时任务。用 Windows 计划任务
#      在外部调GitHub API，通过 repository_dispatch 事件触发。
#
# 去重逻辑：每次触发前检查"本周期（周一/周四）是否已推送过"，
#          避免"14:00 触发 + 开机又触发"造成一周期发两封邮件。
#          同时支持补推：若电脑在周一关机、周三才开机，仍会补发一次。
#
# 用法：
#   .\trigger_workflow.ps1              按计划逻辑触发（计划任务调用此方式）
#   .\trigger_workflow.ps1 -Force       无条件触发（手动测试用）
#   .\trigger_workflow.ps1 -KeepAlive   触发 Keep Alive（防仓库60天无活动）

param(
    [switch]$KeepAlive,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$markerFile = Join-Path $PSScriptRoot '.last_push_date.txt'

# ---------------------------------------------------------------- Token
$tokenFile = Join-Path $PSScriptRoot 'github_token.txt'
if (-not (Test-Path $tokenFile)) {
    Write-Error "找不到 token 文件：$tokenFile"
    exit 1
}
$token = (Get-Content $tokenFile -Raw).Trim()
if ($token -notmatch '^ghp_') {
    Write-Error "github_token.txt 内容无效，应为以 ghp_ 开头的 GitHub Token"
    exit 1
}

# ------------------------------------------------------- 去重 / 补推判断
# 记录的是「已经推送过的计划日」，而不是「推送发生的日子」，
# 这样补推（周一没开机、周三才开机）也能正确标记为已处理周一那一期。
function Get-LastScheduleDay {
    param([datetime]$From)
    $d = $From.Date
    while ($true) {
        if ($d.DayOfWeek -eq 'Monday' -or $d.DayOfWeek -eq 'Thursday') { return $d }
        $d = $d.AddDays(-1)
    }
}

if ($KeepAlive) {
    # Keep Alive 的作用是产生 commit 防止仓库 60 天无活动被停用，
    # 所以 30 天一次足够。开机很频繁，必须限流，否则每次开机都提交一次。
    $keepStamp = Join-Path $PSScriptRoot '.last_keepalive_date.txt'
    if (-not $Force -and (Test-Path $keepStamp)) {
        $raw = (Get-Content $keepStamp -Raw).Trim()
        $last = [datetime]::MinValue
        if ([datetime]::TryParse($raw, [ref]$last)) {
            $days = ((Get-Date) - $last).Days
            if ($days -lt 30) {
                Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] Keep Alive 距上次仅$days 天（<30），跳过。"
                exit 0
            }
        }
    }
    $eventType = 'keep-alive'
}
else {
    if (-not $Force) {
        $today = (Get-Date).Date

        # 只在「计划日当天」推送。若错过了该计划日（电脑关机），
        # 下一个计划日到来时自然覆盖，不需要额外补推逻辑 ——
        # 漏掉的那一期本来也只能补到"上一批新论文"，价值有限，
        # 而补推会让周一/周四各收到两封，反而干扰阅读。
        if ($today.DayOfWeek -ne 'Monday' -and $today.DayOfWeek -ne 'Thursday') {
            Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] 今天不是计划日（周一/周四），跳过。"
            exit 0
        }

        # 同一天重复开机/登录时避免重复推送
        $stampFile = Join-Path $PSScriptRoot ".last_push_date.txt"
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
    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] 已触发 $label（event_type=$eventType）"

    if (-not $KeepAlive) {
        # 记录推送日期，用于下一轮去重判断
        Set-Content -Path $markerFile -Value (Get-Date -Format 'yyyy-MM-dd') -Encoding ASCII -NoNewline
    }
    else {
        Set-Content -Path (Join-Path $PSScriptRoot '.last_keepalive_date.txt') `
                    -Value (Get-Date -Format 'yyyy-MM-dd') -Encoding ASCII -NoNewline
    }
    exit 0
}
catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -eq 401) {
        Write-Error 'Token 无效或已过期 —— 请到 https://github.com/settings/tokens 重新生成'
    }
    elseif ($status -eq 404) {
        Write-Error '仓库或事件类型不存在 —— 确认 workflow 已包含 repository_dispatch 触发器'
    }
    else {
        Write-Error "触发失败 (HTTP $status)：$($_.Exception.Message)"
    }
    exit 1
}