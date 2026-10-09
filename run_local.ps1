# 本地运行 zotero-arxiv-daily
#
#   .\run_local.ps1              正常运行
#   .\run_local.ps1 -Check       只跑配置与连通性预检（不需要凭据）
#
# uv 不在系统 PATH 里，所以这里手动注入工具目录。

$ErrorActionPreference = 'Stop'
$uvDir = 'E:\Paper_Review\.tools\uv'
if (-not (Test-Path "$uvDir\uv.exe")) {
    throw "找不到 uv：$uvDir\uv.exe"
}
$env:PATH = "$uvDir;$env:PATH"

Set-Location $PSScriptRoot

if ($args -contains '-Check') {
    Write-Host "`n=== 1/2 配置校验 ===" -ForegroundColor Cyan
    uv run python scripts_check_config.py
    if ($LASTEXITCODE -ne 0) { throw '配置校验失败' }

    Write-Host "`n=== 2/2 连通性预检 ===" -ForegroundColor Cyan
    uv run python scripts_check_pipeline.py
    if ($LASTEXITCODE -ne 0) { Write-Warning '预检有未通过项，见上方输出' }
    return
}

if (-not (Test-Path '.env')) {
    throw '缺少 .env —— 先运行: Copy-Item .env.example .env，然后填入凭据'
}

Write-Host '使用配置:' -ForegroundColor Cyan
Get-Content config\custom.yaml
Write-Host ''

uv run src/zotero_arxiv_daily/main.py
