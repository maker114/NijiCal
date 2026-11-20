# 发版：改版本号 → 构建校验 → 打 tag 推送 → 由 GitHub Actions 构建并发布
#
# 用法：
#   tool/release.ps1 -Version 2.15.0 -Code 72
#   tool/release.ps1 -Version 2.15.0 -Code 72 -DryRun
#
# 前置：仓库需配置 secret ANDROID_DEBUG_KEYSTORE_BASE64（见 README）。

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][int]$Code,
    [string]$Note = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# 1. 版本号落盘：pubspec / version.dart
Step "写版本号 $Version+$Code"
$pubspec = Join-Path $root 'app/pubspec.yaml'
$text = [IO.File]::ReadAllText($pubspec, [Text.Encoding]::UTF8)
$text = [regex]::Replace($text, '(?m)^version: .*$', "version: $Version+$Code")
[IO.File]::WriteAllText($pubspec, $text, [Text.UTF8Encoding]::new($false))

$verFile = Join-Path $root 'app/lib/version.dart'
$vt = [IO.File]::ReadAllText($verFile, [Text.Encoding]::UTF8)
$vt = [regex]::Replace($vt, "kAppVersion = '[^']*'", "kAppVersion = '$Version'")
$vt = [regex]::Replace($vt, 'kAppVersionCode = \d+', "kAppVersionCode = $Code")
[IO.File]::WriteAllText($verFile, $vt, [Text.UTF8Encoding]::new($false))

# 2. 本地先跑一遍 analyze / test，避免推到 CI 才发现问题
Step '本地校验'
Push-Location (Join-Path $root 'app')
flutter analyze
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'analyze 失败' }
flutter test
if ($LASTEXITCODE -ne 0) { Pop-Location; throw '测试失败' }
Pop-Location

if ($DryRun) {
    Step 'DryRun：只改版本号，不提交'
    git --no-pager diff --stat
    exit 0
}

# 3. 提交 + 打 tag + 推送（CI 会构建并发 Release，同时回写 latest.json）
# -Note 支持多行或用分号分隔；每条写成独立的「- 条目」放进提交正文，
# CI 的清单脚本读正文 → App 更新页据此逐行显示。
$noteLines = @()
if ($Note) {
  $noteLines = $Note -split "(`r?`n|;)" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
$subject = "chore(release): $Version ($Code)"
$body = if ($noteLines.Count -gt 0) { "`n`n" + (($noteLines | ForEach-Object { "- $_" }) -join "`n") } else { '' }
$msg = "$subject$body"
Step "提交：$subject（$($noteLines.Count) 条更新说明）"
git add app/pubspec.yaml app/lib/version.dart
git commit -m $msg

Step "打标签 v$Version 并推送"
# 先同步远端，避免本地落后导致 push 被拒（之前就这样静默失败过）
git fetch origin main
git rebase origin/main
if ($LASTEXITCODE -ne 0) { throw 'rebase origin/main 失败，请手动解决冲突' }

git push origin HEAD:main
if ($LASTEXITCODE -ne 0) { throw 'push main 失败：远程可能有新提交，先 git pull --rebase 再重试' }

git tag "v$Version"
git push origin "v$Version"
if ($LASTEXITCODE -ne 0) { throw 'push tag 失败' }

Write-Host "`n已推送标签 v$Version。" -ForegroundColor Green
Write-Host '到 GitHub → Actions 查看构建；完成后 App 内「检查更新」即可看到新版。'
