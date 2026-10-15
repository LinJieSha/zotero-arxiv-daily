# 校验计划任务的星期/时刻与 trigger_workflow.ps1 的脚本内判定是否一致。
#
# 为什么需要这个脚本：
#   星期在两个文件里各写一份（setup_scheduler.ps1 的触发器、
#   trigger_workflow.ps1 的脚本内判定），不一致时的症状极隐蔽：
#   任务返回 0 但没有邮件，也没有任何错误信息。
#
# 用法：.\audit_weekday.ps1

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$taskName = 'ZoteroArxivDaily'

function Get-PlanList {
    param([string]$Text, [string]$VarName)
    # 取 $VarName = @('a', 'b') 这一行的数组内容。匹配用 ^$VarName 而不是把
    # \$VarName 塞进正则：PowerShell 双引号字符串会先展开变量。
    $line = ($Text -split "`n" | Where-Object { $_ -match ('^\$' + [regex]::Escape($VarName) + '\s*=') } | Select-Object -First 1)
    if (-not $line) { return @() }
    if ($line -notmatch '@\((.*)\)') { return @() }
    return @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ })
}

Write-Host "=== 1. 脚本内计划日与时刻（trigger_workflow.ps1）===" -ForegroundColor Cyan
$triggerText = Get-Content (Join-Path $scriptDir 'trigger_workflow.ps1') -Raw -Encoding UTF8
$scriptDays = Get-PlanList -Text $triggerText -VarName 'PlanDays'
$scriptTimes = Get-PlanList -Text $triggerText -VarName 'PlanTimes'
Write-Host ("  计划日: " + ($scriptDays -join ', '))
Write-Host ("  时刻  : " + ($scriptTimes -join ', '))

Write-Host "`n=== 2. 安装脚本里的计划日与时刻（setup_scheduler.ps1）===" -ForegroundColor Cyan
$setupText = Get-Content (Join-Path $scriptDir 'setup_scheduler.ps1') -Raw -Encoding UTF8
$setupDays = Get-PlanList -Text $setupText -VarName 'PlanDays'
$setupTimes = Get-PlanList -Text $setupText -VarName 'PlanTimes'
Write-Host ("  计划日: " + ($setupDays -join ', '))
Write-Host ("  时刻  : " + ($setupTimes -join ', '))

Write-Host "`n=== 3. 已注册任务的触发器 ===" -ForegroundColor Cyan
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -eq $task) {
    Write-Host "  任务 $taskName 未注册，请先运行 .\setup_scheduler.ps1" -ForegroundColor Red
    exit 1
}
$dayNames = @{ 'Sunday' = 1; 'Monday' = 2; 'Tuesday' = 4; 'Wednesday' = 8; 'Thursday' = 16; 'Friday' = 32; 'Saturday' = 64 }
$taskDays = @()
$taskTimes = @()
foreach ($t in $task.Triggers) {
    switch ($t.CimClass.CimClassName) {
        'MSFT_TaskWeeklyTrigger' {
            $d = [int]$t.DaysOfWeek
            foreach ($k in $dayNames.Keys) { if ($d -band $dayNames[$k]) { $taskDays += $k } }
            $taskTimes += $t.StartBoundary.Substring(11, 5)
        }
        'MSFT_TaskBootTrigger'   { Write-Host "  开机触发 (delay=$($t.Delay))" }
        'MSFT_TaskLogonTrigger'  { Write-Host "  登录触发 (delay=$($t.Delay))" }
        default                  { Write-Host "  $($t.CimClass.CimClassName)" }
    }
}
Write-Host ("  星期: " + (($taskDays | Sort-Object -Unique) -join ', '))
Write-Host ("  时刻: " + (($taskTimes | Sort-Object -Unique) -join ', '))
Write-Host ("  WakeToRun: " + $task.Settings.WakeToRun)
Write-Host ("  StartWhenAvailable: " + $task.Settings.StartWhenAvailable)

Write-Host "`n=== 4. 运行信息 ===" -ForegroundColor Cyan
$info = $task | Get-ScheduledTaskInfo
Write-Host ("  下次运行: " + $info.NextRunTime)
Write-Host ("  上次运行: " + $info.LastRunTime)
Write-Host ("  上次结果: " + $info.LastTaskResult + "   (267011 = 任务从未运行；本机长期不重启时该值无参考意义)")
$today = (Get-Date).DayOfWeek
if ($setupDays -contains $today) {
    Write-Host ("  今天 " + $today + " 是计划日")
} else {
    Write-Host ("  今天 " + $today + " 不是计划日（脚本会跳过，零网络请求）")
}

Write-Host "`n=== 5. 一致性判定 ===" -ForegroundColor Cyan
$ok = $true
if (($scriptDays -join ',') -ne ($setupDays -join ',')) {
    Write-Host "  ✗ 脚本内计划日与安装脚本不一致" -ForegroundColor Red; $ok = $false
}
if (($scriptTimes -join ',') -ne ($setupTimes -join ',')) {
    Write-Host "  ✗ 脚本内时刻与安装脚本不一致" -ForegroundColor Red; $ok = $false
}
if ((($taskDays | Sort-Object -Unique) -join ',') -ne (($setupDays | Sort-Object -Unique) -join ',')) {
    Write-Host "  ✗ 已注册任务的星期与安装脚本不一致（需要重装：.\setup_scheduler.ps1）" -ForegroundColor Red; $ok = $false
}
if ((($taskTimes | Sort-Object -Unique) -join ',') -ne (($setupTimes | Sort-Object -Unique) -join ',')) {
    Write-Host "  ✗ 已注册任务的时刻与安装脚本不一致（需要重装：.\setup_scheduler.ps1）" -ForegroundColor Red; $ok = $false
}
if ($ok) {
    Write-Host "  ✓ 星期与时刻在三处一致" -ForegroundColor Green
}
else {
    exit 1
}