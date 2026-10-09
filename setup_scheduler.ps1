# 安装 / 更新 Windows 计划任务，让论文推送自动跟随开机。
#
# 解决什么问题：
#   GitHub 禁用 fork仓库的 schedule（cron），所以推送靠本机触发。
#   固定在14:00 的问题是 —— 电脑那时若在睡眠/关机就会漏掉。
#   本方案改为「周一/周四 首次开机时触发」，无论几点开机都能赶上。
#
# 触发器设计（三个，缺一不可）：
#   1. 每周一 00:05开机触发 —— 覆盖周一
#   2. 每周四 00:05 开机触发 —— 覆盖周四
#   3. Keep Alive 每 30 天开机触发 —— 防仓库长期无活动被 GitHub 停用
#
# 去重：trigger_workflow.ps1 内置周期判断，一周期只发一次，
#       固定时间触发 + 开机触发不会重复。
#
# 用法：.\setup_scheduler.ps1

$ErrorActionPreference = 'Stop'

$scriptDir  = $PSScriptRoot
$mainScript = Join-Path $scriptDir 'trigger_workflow.ps1'
$keepScript = Join-Path $scriptDir 'trigger_workflow.ps1'
$tokenFile  = Join-Path $scriptDir 'github_token.txt'
$taskName   = 'ZoteroArxivDaily'
$keepTaskName = 'ZoteroArxivKeepAlive'

if (-not (Test-Path $mainScript)) { throw "找不到 trigger_workflow.ps1" }

# --- 1. Token 检查 ---
if (-not (Test-Path $tokenFile)) {
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

# --- 2. 清理旧任务 ---
foreach ($tn in @($taskName, $keepTaskName)) {
    if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false
        Write-Host "已移除旧任务 $tn" -ForegroundColor DarkGray
    }
}

# --- 3. 动作 ---
$commonArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mainScript`""

$paperAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $commonArgs
$keepAction  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "$commonArgs -KeepAlive"

# --- 4. 触发器：每次开机 ---
# Windows 计划任务没有"仅在指定星期开机时触发"这种触发器，只有
# "每次开机"和"每次登录"。这里用「每次开机 + 脚本内按星期判断」实现：
#   - 周一开机 -> 推送
#   - 周四开机 -> 推送
#   - 其余时间开机 -> 脚本判定后直接跳过，零开销、无副作用
# 这样即使周一整天没开机、周三才开机，也会补推一次，不会漏。
$bootTrigger = New-ScheduledTaskTrigger -AtStartup

# 登录时再触发一次，覆盖"开机但未登录"的场景（睡眠唤醒、快速用户切换）
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $paperAction `
    -Trigger @($bootTrigger, $logonTrigger) `
    -Settings $settings `
    -Principal $principal `
    -Description '开机/登录时检查，若为周一或周四且本周期未推送则触发' | Out-Null

# --- 5. Keep Alive：每天开机时检查，脚本内限制每 30 天只做一次 ---
Register-ScheduledTask `
    -TaskName $keepTaskName `
    -Action $keepAction `
    -Trigger $bootTrigger `
    -Settings $settings `
    -Principal $principal `
    -Description '开机时检查，每 30 天触发一次 Keep Alive' | Out-Null

Write-Host "`n计划任务已安装`n" -ForegroundColor Green
Write-Host "【论文推送】$taskName" -ForegroundColor Cyan
Write-Host "  触发    : 每次开机 / 每次登录"
Write-Host "  逻辑    : 仅当今天是周一或周四、且当天尚未推送时才真正触发"
Write-Host ""
Write-Host "【Keep Alive】$keepTaskName" -ForegroundColor Cyan
Write-Host "  触发    : 每次开机（脚本内限制每 30 天只做一次）"
Write-Host ''
Write-Host "常用命令：" -ForegroundColor DarkGray
Write-Host "  查看状态  : Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo"
Write-Host "  立即测试  : Start-ScheduledTask -TaskName $taskName"
Write-Host "  强制推送  : .\trigger_workflow.ps1 -Force"
Write-Host "  删除      : Unregister-ScheduledTask -TaskName $taskName,\`$keepTaskName -Confirm:\`$false"
Write-Host ''
Write-Host "说明：周末或非计划日开机时，脚本会判定后直接退出，不会有任何动作。" -ForegroundColor Yellow