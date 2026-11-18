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
$msg = if ($Note) { "chore(release): $Version ($Code) — $Note" } else { "chore(release): $Version ($Code)" }
Step "提交：$msg"
git add app/pubspec.yaml app/lib/version.dart
git commit -m $msg

Step "打标签 v$Version 并推送"
git tag "v$Version"
git push origin HEAD:main
git push origin "v$Version"

Write-Host "`n已推送标签 v$Version。" -ForegroundColor Green
Write-Host '到 GitHub → Actions 查看构建；完成后 App 内「检查更新」即可看到新版。'
