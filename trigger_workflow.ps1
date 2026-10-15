# 触发 zotero-arxiv-daily 的 GitHub Actions workflow
#
# 背景：GitHub 禁用 fork 仓库的 schedule（cron）定时任务。用 Windows 计划任务
#      在外部调 GitHub API，通过 repository_dispatch 事件触发。
#
# ── 原始规划（2026-10-15 恢复）──────────────────────────────────────────
#   推送日    ：周二、周五
#   触发源    ：开机+3 分钟 / 登录+3 分钟（兜底，覆盖 10:00 时电脑没开/睡眠唤醒）
#               周二 10:00 / 周五 10:00（定点，覆盖整天不关机）
#   单日去重  ：当天只要成功派发过一次，后续任何触发一律跳过（硬性）
#   送达保障  ：派发后回查 Actions 运行结果，确认「邮件已发出 / 0 篇 / 失败」；
#               只有「失败」（想发信却没发出去）才补发一次，每日派发上限 2 次
#
# ── 为什么是周二/周五 ──────────────────────────────────────────────────
#   arXiv 每个公告日 20:00 美东（= 北京次日 08:00）公告一批；分类 feed 每天
#   00:00 美东（= 北京 12:00）重建，只装「前一天公告」的那一批。上午 10:00
#   抓到的就是前一天中午装进 feed 的那批（周二批含整个周末的提交积压）。
#
# ── 回查结果口径 ───────────────────────────────────────────────────────
#   sent       运行日志含 Email sent successfully（邮件已交给 SMTP）
#   no-papers  当天 0 篇，本就不发信（arXiv 假期/周末，不是故障，不补发）
#   failed     运行出错、邮件没发出去 → 自动补发一次
#   unknown    回查超时；为避免重复邮件不再补发，用 -Status 或 Actions 页面人工确认
#   注意：口径是「Actions 日志确认 SMTP 已发出」；能否进收件箱（垃圾箱拦截等）
#   属邮箱侧，脚本观测不到，需偶尔翻一下垃圾箱。
#
# ── 历史坑（保留备忘）─────────────────────────────────────────────────
#   坑21：$status 与 param([switch]$Status 大小写不敏感冲突 → 派发成功后必崩，
#         去重标记写不进去。已改用 $httpStatus。
#   坑22：旧版把 outcome=unknown 当可重试，而 unknown 是唯一会写的值 →
#         每个计划日固定派发 3 次。本版取消该逻辑：一天只推一次，失败才补发。
#
# 用法：
#   .\trigger_workflow.ps1              按计划逻辑触发（计划任务调用）
#   .\trigger_workflow.ps1 -Force       无条件触发（手动测试）
#   .\trigger_workflow.ps1 -Probe       只探测网络，不推送（仅供人工诊断）
#   .\trigger_workflow.ps1 -KeepAlive   触发 Keep Alive（防仓库 60 天无活动）
#   .\trigger_workflow.ps1 -Status      打印本地状态后退出（诊断用）

param(
    [switch]$KeepAlive,
    [switch]$Force,
    [switch]$Probe,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 默认不加载 System.Net.Http。派发与回查都走 HttpClient。
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop }
catch { Add-Type -AssemblyName System.Net -ErrorAction SilentlyContinue }

# ── 计划配置（与 setup_scheduler.ps1 保持一致，audit_weekday.ps1 会校验）──
$PlanDays  = @('Tuesday', 'Friday')
$PlanTimes = @('10:00')
# 正常 1 次派发；+1 次仅当运行「失败」（未发信且非 0 篇）时补发
$MaxDispatchesPerDay = 2
# 派发后回查：首次等待上限（完整流水线实测约 8.5 分钟）
$VerifyTimeoutMinutes = 16
# 补发后的回查上限（失败通常几十秒内就体现）
$RetryVerifyTimeoutMinutes = 8
$VerifyPollSeconds   = 30

$RepoApiBase  = 'https://api.github.com/repos/LinJieSha/zotero-arxiv-daily'
$WorkflowName = 'Send emails twice a week'

$scriptDir   = $PSScriptRoot
$markerFile  = Join-Path $scriptDir '.last_push_date.txt'
$outcomeFile = Join-Path $scriptDir '.last_run_outcome.json'
$failLog     = Join-Path $scriptDir '.trigger_failures.log'
$runLogDir   = Join-Path $scriptDir 'logs'
$runLog      = Join-Path $runLogDir 'trigger_runs.log'
$todayStr    = (Get-Date).ToString('yyyy-MM-dd')

# ---------------------------------------------------------------- 日志
function Write-Log {
    param([string]$Message, [switch]$IsError)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    # 「跳过」类消息不落盘（开机/登录触发每天最多出现两次，没必要）；
    # 其余（已触发 / 回查结果 / 失败）都记入 logs/trigger_runs.log。
    if ($Message -like '*跳过*') {
        Write-Output "[$ts] $Message"
        return
    }
    if ($IsError) {
        # 失败才额外落盘到 .trigger_failures.log。成功不记，避免日志膨胀。
        # 只保留最近 200 条。
        Add-Content -Path $failLog -Value "[$ts] $Message" -Encoding UTF8
        $all = Get-Content $failLog -Encoding UTF8
        if ($all.Count -gt 200) {
            $all | Select-Object -Last 200 | Set-Content $failLog -Encoding UTF8
        }
    }
    if (-not (Test-Path $runLogDir)) { New-Item -ItemType Directory -Path $runLogDir -Force | Out-Null }
    Add-Content -Path $runLog -Value "[$ts] $Message" -Encoding UTF8
    $allRun = Get-Content $runLog -Encoding UTF8
    if ($allRun.Count -gt 400) {
        $allRun | Select-Object -Last 400 | Set-Content $runLog -Encoding UTF8
    }
    Write-Output "[$ts] $Message"
}

# ------------------------------------------------- 当天结果文件
# outcome 语义（由回查自动写入）：
#   pending    已派发，正在回查
#   sent       日志确认 Email sent successfully
#   no-papers  日志确认 0 篇（不发信，正常）
#   failed     运行失败 → 允许补发一次（dispatches < 上限时）
#   unknown    回查超时 → 不补发（防重复邮件）
function Get-TodayOutcome {
    if (-not (Test-Path $outcomeFile)) { return $null }
    try {
        $o = Get-Content $outcomeFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($o.date -eq $todayStr) { return $o } else { return $null }
    }
    catch {
        return $null
    }
}

function Save-TodayOutcome {
    param([string]$Outcome, [int]$DispatchCount, $RunId = $null)
    $obj = [ordered]@{
        date       = $todayStr
        outcome    = $Outcome
        dispatches = $DispatchCount
        run_id     = $RunId
        updated    = (Get-Date).ToString('s')
    }
    $json = $obj | ConvertTo-Json -Compress
    Set-Content -Path $outcomeFile -Value $json -Encoding UTF8
}

function Get-TodayDispatchCount {
    $o = Get-TodayOutcome
    if ($null -eq $o) { return 0 }
    if ($null -eq $o.dispatches) { return 1 }
    return [int]$o.dispatches
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

# ---------------------------------------------------------------- GitHub API
# 统一的 API 入口：派发（POST）与回查（GET）都走这里。
# 网络异常不抛出（返回 status=0），由调用方判断。
# 注意：logs 端点返回 zip（二进制），所以 bytes 与解码后的 content 都返回。
function Invoke-GitHubApi {
    param([string]$Uri, [string]$Method = 'GET', [string]$Body = $null)
    $client = New-Object System.Net.Http.HttpClient
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        $client.DefaultRequestHeaders.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/vnd.github+json'))
        $client.DefaultRequestHeaders.UserAgent.Add([System.Net.Http.Headers.ProductInfoHeaderValue]::new('zotero-daily-trigger', '1.0'))
        if ($Method -eq 'POST') {
            $content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, 'application/json')
            $resp = $client.PostAsync($Uri, $content).GetAwaiter().GetResult()
            $content.Dispose()
        }
        else {
            $resp = $client.GetAsync($Uri).GetAwaiter().GetResult()
        }
        # ⚠️ 变量名用 $httpStatus：$status 会与 param([switch]$Status 大小写
        #    不敏感冲突（坑 21），赋 Int32 必抛 MetadataError。
        $httpStatus = [int]$resp.StatusCode
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        return @{ status = $httpStatus; content = $text; bytes = $bytes }
    }
    catch {
        return @{ status = 0; content = $_.Exception.Message; bytes = $null }
    }
    finally {
        $client.Dispose()
    }
}

# 在 run 列表里找「本次派发创建的那个 run」。
# GitHub 的 created_at 是定长 UTC ISO 串（…THH:MM:SSZ），字典序 == 时间序，
# 所以直接字符串比较。列表按新→旧排序，取第一个 created_at >= 派发时刻的。
function Find-DispatchRun {
    param([string]$SinceIso)
    $r = Invoke-GitHubApi -Uri "$RepoApiBase/actions/runs?event=repository_dispatch&per_page=10"
    if ($r.status -ne 200) { return $null }
    $runs = @((($r.content | ConvertFrom-Json).workflow_runs))
    if ($null -eq $runs) { return $null }
    foreach ($run in $runs) {
        if ([string]$run.name -ne $WorkflowName) { continue }
        if ([string]$run.created_at -lt $SinceIso) { continue }
        return $run
    }
    return $null
}

# 下载某次运行的日志 zip，在内存里解包扫描，判定结果。
# 返回 sent / no-papers / failed / unknown（日志还没准备好）。
function Read-RunOutcomeText {
    param($RunId)
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }
    $r = Invoke-GitHubApi -Uri "$RepoApiBase/actions/runs/$RunId/logs"
    if ($r.status -ne 200 -or $null -eq $r.bytes) { return 'unknown' }
    $ms = New-Object System.IO.MemoryStream
    $zip = $null
    try {
        $ms.Write($r.bytes, 0, $r.bytes.Length)
        $ms.Position = 0
        $zip = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Read)
        $outcome = 'failed'
        $zeroPapers = $false
        foreach ($entry in $zip.Entries) {
            if ($entry.Name -notlike '*.txt') { continue }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            $logText = $reader.ReadToEnd()
            $reader.Close()
            if ($logText -match 'Email sent successfully') { $outcome = 'sent'; break }
            if ($logText -match 'Total 0 papers retrieved' -or
                $logText -match 'No arxiv papers found' -or
                $logText -match 'No new papers found\. No email will be sent') {
                $zeroPapers = $true
            }
        }
        if ($outcome -ne 'sent' -and $zeroPapers) { $outcome = 'no-papers' }
        return $outcome
    }
    catch {
        return 'unknown'
    }
    finally {
        if ($null -ne $zip) { $zip.Dispose() }
        $ms.Dispose()
    }
}

# 轮询直到 run 完成并读出结果；超时返回 unknown。
function Wait-RunOutcome {
    param([string]$SinceIso, [int]$TimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $VerifyPollSeconds
        $run = Find-DispatchRun -SinceIso $SinceIso
        if ($null -eq $run) { continue }
        if ([string]$run.status -ne 'completed') { continue }
        $outcome = Read-RunOutcomeText -RunId $run.id
        if ($outcome -eq 'unknown') { continue }   # 日志未就绪，继续等
        return @{ outcome = $outcome; runId = $run.id }
    }
    return @{ outcome = 'unknown'; runId = $null }
}

# ---------------------------------------------------------------- 状态打印
if ($Status) {
    Write-Output "今天         : $todayStr ($( (Get-Date).DayOfWeek ))"
    Write-Output "计划日       : $($PlanDays -join ', ')，时刻 $($PlanTimes -join ', ')"
    Write-Output "单日派发上限 : $MaxDispatchesPerDay（正常 1 次 + 失败补发 1 次）"
    $o = Get-TodayOutcome
    if ($null -ne $o) {
        $runIdStr = if ($o.run_id) { $o.run_id } else { '—' }
        Write-Output "当天结果     : $($o.outcome)（已派发 $($o.dispatches) 次，run $runIdStr，更新于 $($o.updated)）"
    }
    else {
        Write-Output '当天结果     : （无记录）'
    }
    if (Test-Path $markerFile) {
        Write-Output "上次派发日期 : $((Get-Content $markerFile -Raw).Trim())"
    }
    else {
        Write-Output '上次派发日期 : （无）'
    }
    if (Test-Path $runLog) {
        Write-Output '最近 10 行 logs/trigger_runs.log:'
        Get-Content $runLog -Tail 10 | ForEach-Object { Write-Output "   $_" }
    }
    exit 0
}

# ---------------------------------------------------------------- Keep Alive
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
    $r = Invoke-GitHubApi -Uri "$RepoApiBase/dispatches" -Method 'POST' -Body (@{ event_type = 'keep-alive' } | ConvertTo-Json)
    if ($r.status -lt 200 -or $r.status -ge 300) {
        Write-Log "Keep Alive 触发失败：HTTP $($r.status) $($r.content)" -IsError
        exit 1
    }
    Set-Content -Path $keepStamp -Value $todayStr -Encoding ASCII -NoNewline
    Write-Log '已触发 Keep Alive（event_type=keep-alive）'
    exit 0
}

# ---------------------------------------------------------------- 主判定
$dispatchCount = Get-TodayDispatchCount
$alreadyPushed = (Test-Path $markerFile) -and ((Get-Content $markerFile -Raw).Trim() -eq $todayStr)
$todayOutcome  = Get-TodayOutcome
$needDispatch  = $false
$retryReason   = $null

if (-not $Force) {
    # ① 星期门控：非计划日零网络请求
    if ($PlanDays -notcontains (Get-Date).DayOfWeek) {
        Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] 今天不是计划日（$($PlanDays -join '/')），跳过。"
        exit 0
    }
    # ② 单日去重：当天已派发过 → 一律跳过。唯一例外：上次运行「失败」
    #    （想发信却没发出去）且未达派发上限 → 补发一次。
    if ($alreadyPushed) {
        if ($null -ne $todayOutcome -and
            [string]$todayOutcome.outcome -eq 'failed' -and
            $dispatchCount -lt $MaxDispatchesPerDay) {
            $needDispatch = $true
            $retryReason = "上次运行失败（run $($todayOutcome.run_id)），补发（第 $($dispatchCount + 1) 次）"
        }
        else {
            Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] 今天已推送过，跳过。"
            exit 0
        }
    }
    elseif ($dispatchCount -ge $MaxDispatchesPerDay) {
        Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] 今天已派发 $dispatchCount 次（上限 $MaxDispatchesPerDay），跳过。"
        exit 0
    }
    else {
        $needDispatch = $true
    }
}
else {
    $needDispatch = $true
}

# ---------------------------------------------------------------- 探测
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

# ---------------------------------------------------------------- 派发 + 回查
$finalOutcome = 'unknown'
$finalRunId   = $null
$roundsLeft   = $MaxDispatchesPerDay - $dispatchCount
if ($roundsLeft -lt 1) { $roundsLeft = 1 }

for ($round = 1; $round -le $roundsLeft; $round++) {
    $sinceIso = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $r = Invoke-GitHubApi -Uri "$RepoApiBase/dispatches" -Method 'POST' -Body (@{ event_type = 'scheduled-run' } | ConvertTo-Json)

    if ($r.status -lt 200 -or $r.status -ge 300) {
        # 派发失败：不写标记、不计数 —— 后续的开机/登录触发会自然再试。
        # 401 = token 失效，唯一必须人工处理的问题；422 见坑 20（客户端侧问题）。
        if ($r.status -eq 401) {
            Write-Log '触发失败：GitHub Token 无效或已过期（HTTP 401）。需在 https://github.com/settings/tokens 新建 token 并更新 github_token.txt' -IsError
        }
        elseif ($r.status -eq 422) {
            Write-Log '触发失败：HTTP 422 —— 客户端兼容性问题，请用脚本内置的 HttpClient 路径重试' -IsError
        }
        elseif ($r.status -eq 0) {
            Write-Log "触发失败（网络不可达）—— $($r.content)" -IsError
        }
        else {
            Write-Log "触发失败：HTTP $($r.status) $($r.content)" -IsError
        }
        exit 1
    }

    # 派发成功：立即写去重标记（防止并发的开机/登录触发重复派发）
    Set-Content -Path $markerFile -Value $todayStr -Encoding ASCII -NoNewline
    $dispatchCount++
    Save-TodayOutcome -Outcome 'pending' -DispatchCount $dispatchCount -RunId $null
    $suffix = if ($retryReason -and $round -eq 1) { "（$retryReason）" } else { '' }
    Write-Log "已触发 论文推送（event_type=scheduled-run，今日第 $dispatchCount 次派发）$suffix；开始回查运行结果..."

    # 回查：首轮流长等待，补发轮短等待（失败通常很快体现）
    $timeoutMin = if ($round -eq 1) { $VerifyTimeoutMinutes } else { $RetryVerifyTimeoutMinutes }
    $res = Wait-RunOutcome -SinceIso $sinceIso -TimeoutMinutes $timeoutMin
    $finalOutcome = $res.outcome
    $finalRunId   = $res.runId
    Save-TodayOutcome -Outcome $finalOutcome -DispatchCount $dispatchCount -RunId $finalRunId

    if ($finalOutcome -ne 'failed') { break }
    if ($round -lt $roundsLeft) {
        Write-Log "回查结果：运行失败（run $finalRunId，未发信且非 0 篇），自动补发一次" -IsError
    }
}

# ---------------------------------------------------------------- 结果汇总
switch ($finalOutcome) {
    'sent' {
        Write-Log "结果确认：邮件已发出（run $finalRunId 日志含 Email sent successfully）"
    }
    'no-papers' {
        Write-Log "结果确认：当天 0 篇，未发邮件（arXiv 假期/周末属正常，非故障）（run $finalRunId）"
    }
    'failed' {
        Write-Log "结果：运行失败且补发后仍未成功（run $finalRunId）——请到 Actions 页面查看日志" -IsError
    }
    'unknown' {
        Write-Log "结果未确认：回查超时（run $finalRunId）。为避免重复邮件不再补发，请用 .\trigger_workflow.ps1 -Status 或 Actions 页面人工确认" -IsError
    }
}
exit 0
