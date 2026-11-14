# 把本地仓库推到 GitHub，然后告诉你去哪下 ipa
# 用法（在 G:\取件码小程序 下）：
#   powershell -ExecutionPolicy Bypass -File .\scripts\推到GitHub并编译.ps1 -Repo https://github.com/你的用户名/仓库名.git

param(
    [Parameter(Mandatory = $true)]
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
$git = 'C:\Program Files\Git\cmd\git.exe'
if (-not (Test-Path $git)) { $git = 'git' }

Set-Location (Split-Path -Parent $PSScriptRoot)

if ($Repo -notmatch '\.git$') { $Repo = $Repo.TrimEnd('/') + '.git' }

$m = [regex]::Match($Repo, 'github\.com[:/](?<owner>[^/]+)/(?<name>[^/]+?)(\.git)?$')
if (-not $m.Success) {
    Write-Host "这个地址看起来不是 GitHub 仓库：$Repo" -ForegroundColor Red
    exit 1
}
$owner = $m.Groups['owner'].Value
$name  = $m.Groups['name'].Value -replace '\.git$', ''
$actions = "https://github.com/$owner/$name/actions/workflows/ios-unsigned.yml"

Write-Host "仓库：$owner/$name" -ForegroundColor Cyan

& $git remote remove origin 2>$null
& $git remote add origin $Repo
Write-Host "推送中…（可能要求你登录 GitHub）" -ForegroundColor Yellow
& $git push -u origin main

Write-Host ""
Write-Host "推送完成。编译地址：" -ForegroundColor Green
Write-Host "  $actions" -ForegroundColor Green
Write-Host "打开后点右侧「Run workflow」→ 等 3~5 分钟 → 页面底部 Artifacts 下 PickupCode-unsigned-ipa.zip"
Start-Process $actions
