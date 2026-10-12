# ============================================================
#  get-qqbot.ps1 —— 一行安装（Windows，不需要 Docker）
#
#  它会：把部署包拉到一个固定目录 → 交给包里的 host\install-host.ps1 干正事。
#  install-host.ps1 自己分层判断（已有 Node / dsh 就不动），本脚本只负责"取包"。
#
#  用法：
#    # 先下载再跑（推荐，参数好传）：
#    irm https://raw.githubusercontent.com/zfqxuz/qqbot-deploy/main/host/get-qqbot.ps1 -OutFile "$env:TEMP\get-qqbot.ps1"
#    powershell -ExecutionPolicy Bypass -File "$env:TEMP\get-qqbot.ps1" -Check
#    powershell -ExecutionPolicy Bypass -File "$env:TEMP\get-qqbot.ps1" -QQ 123456789
#
#    # 一行流（不给参数时等价于默认安装；要参数就用上面那种）：
#    irm https://raw.githubusercontent.com/zfqxuz/qqbot-deploy/main/host/get-qqbot.ps1 | iex
#
#  参数原样透传给 host\install-host.ps1（-QQ / -Port / -DataRoot / -Check / -NoAutostart /
#  -UpgradeDsh / -DshVersion / -SkipDsh 都认）。
param(
  [string]$QQ = '',
  [int]$Port = 3081,
  [int]$ConsolePort = 8798,
  [string]$DataRoot = "$env:USERPROFILE\qqbot",
  [switch]$Check,
  [switch]$NoAutostart,
  [switch]$UpgradeDsh,
  [switch]$SkipDsh,
  [string]$DshVersion = '',
  [string]$Repo = 'zfqxuz/qqbot-deploy',
  [string]$Ref = 'main',
  [string]$Src = "$env:USERPROFILE\qqbot\src\qqbot-deploy",
  [switch]$Refresh
)
$ErrorActionPreference = 'Stop'
function Say($m) { Write-Host "[get-qqbot] $m" }
function Die($m) { Write-Host "[get-qqbot] x $m" -ForegroundColor Red; exit 1 }

function Invoke-Installer($root) {
  $script = Join-Path $root 'host\install-host.ps1'
  if (-not (Test-Path $script)) { Die "$root 里没有 host\install-host.ps1（包不完整）" }
  $argv = @()
  if ($QQ) { $argv += @('-QQ', $QQ) }
  $argv += @('-Port', "$Port", '-ConsolePort', "$ConsolePort", '-DataRoot', $DataRoot)
  if ($Check) { $argv += '-Check' }
  if ($NoAutostart) { $argv += '-NoAutostart' }
  if ($UpgradeDsh) { $argv += '-UpgradeDsh' }
  if ($SkipDsh) { $argv += '-SkipDsh' }
  if ($DshVersion) { $argv += @('-DshVersion', $DshVersion) }
  Say "开始安装（$script）"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $script @argv
  exit $LASTEXITCODE
}

# ---------- 1) 已经在部署包里就直接用 ----------
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($here) {
  if (Test-Path (Join-Path $here 'install-host.ps1')) { Say "用当前目录里的部署包：$here"; Invoke-Installer $here }
  $parent = Split-Path -Parent $here
  if ($parent -and (Test-Path (Join-Path $parent 'host\install-host.ps1'))) { Say "用当前目录里的部署包：$parent"; Invoke-Installer $parent }
}

# ---------- 2) 取包 ----------
if ((-not $Refresh) -and (Test-Path (Join-Path $Src 'host\install-host.ps1'))) {
  Say "复用已经拉好的部署包：$Src（要更新：加 -Refresh）"
} else {
  $zip = Join-Path $env:TEMP "qqbot-deploy-$Ref.zip"
  $url = "https://github.com/$Repo/archive/refs/heads/$Ref.zip"
  Say "下载部署包：$url"
  try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing } catch { Die "下载失败：$($_.Exception.Message)" }
  $tmp = Join-Path $env:TEMP ("qqbot-unzip-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try { Expand-Archive -Path $zip -DestinationPath $tmp -Force } catch { Die "解压失败：$($_.Exception.Message)" }

  $found = Get-ChildItem -Path $tmp -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'host\install-host.ps1') } | Select-Object -First 1
  if (-not $found) { Die "包结构和预期不一致：没找到 host\install-host.ps1" }
  if (Test-Path $Src) { Remove-Item -Recurse -Force $Src }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Src) | Out-Null
  Copy-Item -Recurse -Force $found.FullName $Src
  Remove-Item -Recurse -Force $tmp
  Say "部署包就位：$Src"
}

# ---------- 3) 交给真正的安装器 ----------
Invoke-Installer $Src
