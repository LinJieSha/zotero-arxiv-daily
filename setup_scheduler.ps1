# 安装 / 更新 Windows 计划任务，让论文推送自动跟随开机。
#
# 解决什么问题：
#   GitHub 禁用 fork 仓库的 schedule（cron），所以推送靠本机触发。
#   固定时刻触发的问题是 —— 电脑那时若在睡眠/关机就会漏掉。
#   本方案用「开机 / 登录 / 定点」多路触发 + 当天去重，任何一种能赶上就发。
#
# 触发器设计（4 个，2026-10-15 恢复原始规划）：
#   1. 开机 +3 分钟       —— 延迟等代理软件启动；覆盖「10:00 时电脑还关着」
#   2. 登录 +3 分钟       —— 覆盖睡眠唤醒、快速用户切换
#   3. 周二 10:00         —— 定点主推送
#   4. 周五 10:00         —— 定点主推送
#
# 为什么是周二/周五：
#   arXiv 每个公告日 20:00 美东（= 北京次日 08:00）公告一批，分类 feed 每天
#   00:00 美东（= 北京 12:00）重建、只装「前一天公告」的那一批。上午 10:00
#   抓到的就是前一天中午装进 feed 的那批（周二批含整个周末的提交积压）。
#
# 为什么只有一个定点时刻（不再设 14:00/19:00 重试）：
#   送达保障不靠「多推几次」，改由 trigger_workflow.ps1 派发后回查 Actions
#   运行结果完成：确认「邮件已发出 / 0 篇（正常）/ 失败」。只有失败才自动
#   补发一次（每日派发上限 2 次）。0 篇不补发 —— 周末与 arXiv 假期本就没有批次。
#
# 任务时限 30 分钟：回查要等 Actions 完整跑完一次流水线（实测约 8.5 分钟），
#   加上轮询余量。脚本在等待期间只是每 30 秒发一个 GET，开销可忽略。
#
# 睡眠：设置里打开 -WakeToRun，让 10:00 到点时把电脑从睡眠唤醒。
#   （合盖睡眠时若唤醒被 BIOS 禁用仍会漏，靠开机/登录触发兜底。）
#
# 去重：trigger_workflow.ps1 内置"当天是否已派发"判断（硬性），
#       上述触发器共用同一标记，一天最多一封（运行失败自动补发一次除外）。
#
# 用法：
#   .\setup_scheduler.ps1            正常安装/更新两个计划任务
#   .\setup_scheduler.ps1 -DryRun    只校验（星期一致性、token、VBS 内容、触发器列表），
#                                     不注册任务、不触碰任务计划程序

param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$scriptDir  = $PSScriptRoot
$mainScript = Join-Path $scriptDir 'trigger_workflow.ps1'
$tokenFile  = Join-Path $scriptDir 'github_token.txt'
$taskName     = 'ZoteroArxivDaily'
$keepTaskName = 'ZoteroArxivKeepAlive'

# 计划日的唯一来源。trigger_workflow.ps1 里的 $PlanDays 必须与此一致。
$PlanDays = @('Tuesday', 'Friday')
# 每天唯一的定点推送时刻（送达保障在脚本内完成，不再设 14:00/19:00）
$PlanTimes = @('10:00')

if (-not (Test-Path $mainScript)) { throw "找不到 trigger_workflow.ps1" }

# --- 0. 星期一致性检查 ---
# 星期在两个文件里各写一份（这里是触发器，那里是脚本内判定），
# 不一致时的症状极隐蔽：任务成功返回 0 但没有邮件，也没有任何报错。
function Get-PlanList {
    param([string]$Text, [string]$VarName)
    # 取 $VarName = @('a', 'b') 这一行的数组内容。用 ^$VarName 而不是
    # 正则里的 \$PlanDays：PowerShell 双引号字符串会先展开 $PlanDays。
    $line = ($Text -split "`n" | Where-Object { $_ -match ('^\$' + [regex]::Escape($VarName) + '\s*=') } | Select-Object -First 1)
    if (-not $line) { return @() }
    if ($line -notmatch '@\((.*)\)') { return @() }
    return @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ })
}

$triggerText = Get-Content $mainScript -Raw -Encoding UTF8
$scriptPlanDays = Get-PlanList -Text $triggerText -VarName 'PlanDays'
$scriptPlanTimes = Get-PlanList -Text $triggerText -VarName 'PlanTimes'
$setupText = Get-Content $PSCommandPath -Raw -Encoding UTF8
$setupDays = Get-PlanList -Text $setupText -VarName 'PlanDays'
$setupTimes = Get-PlanList -Text $setupText -VarName 'PlanTimes'

if (($scriptPlanDays -join ',') -ne ($setupDays -join ',')) {
    throw ("星期配置不一致：setup_scheduler.ps1 = $($setupDays -join ','); " +
           "trigger_workflow.ps1 = $($scriptPlanDays -join ',')。请先改齐再安装。")
}
if (($scriptPlanTimes -join ',') -ne ($setupTimes -join ',')) {
    throw ("时刻配置不一致：setup_scheduler.ps1 = $($setupTimes -join ','); " +
           "trigger_workflow.ps1 = $($scriptPlanTimes -join ',')。请先改齐再安装。")
}
Write-Host "计划日 $($setupDays -join '/')，时刻 $($setupTimes -join '/')（trigger_workflow.ps1 一致）" -ForegroundColor DarkGray

# --- 1. Token 检查 ---
if (-not (Test-Path $tokenFile)) {
    if ($DryRun) {
        throw '找不到 github_token.txt（DryRun 也要求 token 文件存在，仅检查格式）'
    }
    Write-Host "`n需要先创建 token 文件。" -ForegroundColor Yellow
    Write-Host "1) 打开 https://github.com/settings/tokens/new"
    Write-Host "2) Note 填 zotero-daily-trigger，Expiration 选 90 days"
    Write-Host "3) Permissions -> Repository permissions -> 勾选 repo"
    Write-Host "4) 生成后复制 ghp_... 开头的 token"
    Write-Host ''
    Read-Host "准备好后按回车继续（会自动打开记事本）" | Out-Null
    notepad $tokenFile
    Write-Host "`n请粘贴 token 并保存记事本，然后按回车继续" -ForegroundColor Yellow
    Read-Host | Out-Null
}
$token = (Get-Content $tokenFile -Raw).Trim()
if ($token -notmatch '^ghp_') { throw "github_token.txt 内容无效，应为 ghp_ 开头的 token" }

# --- 2. 清理旧任务（DryRun 跳过） ---
if (-not $DryRun) {
    foreach ($tn in @($taskName, $keepTaskName)) {
        if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false
            Write-Host "已移除旧任务 $tn" -ForegroundColor DarkGray
        }
    }
}

# --- 3. 动作：用 wscript.exe 启动，全程无窗口 ---
#
# 为什么不用 powershell.exe -WindowStyle Hidden：
#   PowerShell 是控制台程序，Windows 会先创建控制台窗口、再处理
#   -WindowStyle Hidden，所以任务运行时仍会闪出一个黑框。
#   WshShell.Run(cmd, 0, False) 的 0 = SW_HIDE，
#   进程从创建那一刻起就没有窗口，不会闪。

$vbsPaper = Join-Path $scriptDir 'run_hidden.vbs'
$vbsKeep  = Join-Path $scriptDir 'run_hidden_keepalive.vbs'

# VBS 内容保持纯 ASCII，用 ASCII 编码写盘，避免任何 BOM/编码坑。
# 用字符串数组逐行拼接，而不是 here-string —— here-string 里的
# 双引号和变量插值很容易写错（这个文件已经踩过一次）。
function New-LauncherVbs {
    param([string]$ScriptPath, [string]$ExtraArg = '')
    # VBS 字符串里要保留引号，必须写成两个连续引号（""）。
    # 这里用字符码拼接，避免在 PowerShell 里写嵌套同类引号被吞掉。
    $q  = [char]34
    $qq = [string]$q + [string]$q
    $cmdLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' +
               $qq + $ScriptPath + $qq + $ExtraArg
    $lines = @(
        "' Auto-generated by setup_scheduler.ps1 -- do not edit by hand.",
        "' Launches PowerShell with no visible window (SW_HIDE = 0).",
        'Option Explicit',
        'Dim sh, cmd',
        ('Set sh = CreateObject(' + $q + 'Wscript.Shell' + $q + ')'),
        ('cmd = ' + $q + $cmdLine + $q),
        'sh.Run cmd, 0, False'
    )
    return $lines -join "`r`n"
}

$vbsPaperContent = New-LauncherVbs -ScriptPath $mainScript
$vbsKeepContent  = New-LauncherVbs -ScriptPath $mainScript -ExtraArg ' -KeepAlive'
if ($DryRun) {
    Write-Host "`n[DryRun] run_hidden.vbs 将要写入的内容：" -ForegroundColor DarkGray
    $vbsPaperContent -split "`r`n" | ForEach-Object { Write-Host "   $_" }
}
else {
    Set-Content -Path $vbsPaper -Value $vbsPaperContent -Encoding ASCII
    Set-Content -Path $vbsKeep  -Value $vbsKeepContent  -Encoding ASCII
}

$paperAction = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsPaper`""
$keepAction  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsKeep`""

# --- 4. 触发器 ---
# Windows 计划任务没有"仅在指定星期开机时触发"这种触发器，只有
# "每次开机"和"每次登录"。要覆盖「整天没开关机」的场景，
# 必须额外加「固定时刻」触发器。
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootTrigger.Delay = 'PT3M'

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$logonTrigger.Delay = 'PT3M'

# 周二 / 周五各一个定点触发（10:00）。送达保障与失败补发都在脚本内完成。
$triggers = @($bootTrigger, $logonTrigger)
foreach ($day in $PlanDays) {
    foreach ($time in $PlanTimes) {
        $triggers += New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $time
    }
}

if ($DryRun) {
    Write-Host "`n[DryRun] 将要注册的触发器：" -ForegroundColor DarkGray
    Write-Host '   开机+3分钟 / 登录+3分钟'
    foreach ($day in $PlanDays) { foreach ($time in $PlanTimes) { Write-Host "   $day $time" } }
    Write-Host '   WakeToRun=是, StartWhenAvailable=是, ExecutionTimeLimit=30 分钟, MultipleInstances=IgnoreNew'
    Write-Host "`n[DryRun] 校验通过，未做任何改动。要真正安装请运行不带 -DryRun 的 .\setup_scheduler.ps1" -ForegroundColor Green
    exit 0
}

# 时限 30 分钟：脚本派发后要回查 Actions 运行结果（完整流水线约 8.5 分钟 + 轮询余量）
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -WakeToRun `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $paperAction `
    -Trigger $triggers `
    -Settings $settings `
    -Principal $principal `
    -Description "开机/登录(延迟3分钟) + $($PlanDays -join '/') $($PlanTimes -join ',')；当天已派发则跳过；派发后回查运行结果，失败自动补发一次（每日上限 2 次派发）" | Out-Null

# --- 5. Keep Alive：开机时检查，脚本内限制每 30 天只做一次 ---
Register-ScheduledTask `
    -TaskName $keepTaskName `
    -Action $keepAction `
    -Trigger $bootTrigger `
    -Settings $settings `
    -Principal $principal `
    -Description '开机时检查，每 30 天触发一次 Keep Alive' | Out-Null

Write-Host "`n计划任务已安装`n" -ForegroundColor Green
Write-Host "【论文推送】$taskName" -ForegroundColor Cyan
Write-Host "  触发器  :"
Write-Host "    1. 开机+3分钟 / 登录+3分钟（等代理软件就绪，兜底）"
Write-Host "    2. $($PlanDays -join ' / ') $($PlanTimes -join ' / ')（定点主推送）"
Write-Host "  逻辑    : 仅当今天是计划日、且当天尚未派发时才真正触发；一天一次"
Write-Host "  送达    : 派发后脚本回查 Actions 运行结果（邮件已发/0篇/失败），失败自动补发一次"
Write-Host "  睡眠    : -WakeToRun 已开启，到点会唤醒电脑"
Write-Host ""
Write-Host "【Keep Alive】$keepTaskName" -ForegroundColor Cyan
Write-Host "  触发    : 每次开机+3分钟（脚本内限制每 30 天只做一次）"
Write-Host ""
Write-Host "校验：" -ForegroundColor DarkGray
Write-Host "  .\audit_weekday.ps1          星期/时刻三处一致性 + 下次运行时间"
Write-Host ""
Write-Host "常用命令：" -ForegroundColor DarkGray
Write-Host "  查看状态  : Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo"
Write-Host "  立即测试  : Start-ScheduledTask -TaskName $taskName"
Write-Host "  强制推送  : .\trigger_workflow.ps1 -Force"
Write-Host "  查看状态  : .\trigger_workflow.ps1 -Status"
Write-Host "  查看失败  : Get-Content .trigger_failures.log -Tail 20"
Write-Host "  查看运行  : Get-Content logs\trigger_runs.log -Tail 20"
Write-Host "  删除      : Unregister-ScheduledTask -TaskName $taskName,\`$keepTaskName -Confirm:\`$false"
Write-Host ""
Write-Host "说明：所有触发器共享去重标记，一天只推一次（运行失败自动补发一次）。" -ForegroundColor Yellow
Write-Host "提示：LastTaskResult 在本机（长期不重启、LogonType=Interactive）不能证明任务跑过，" -ForegroundColor DarkGray
Write-Host "      判断是否触发请看 logs\trigger_runs.log 或 Actions 页面的运行记录。" -ForegroundColor DarkGray