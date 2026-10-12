# install-host.ps1 —— Windows 上的"不用 Docker"安装
#
# 做什么：装 Node（缺则用 winget）→ npm 装 dsh → 拉桥接/插件源码 → 用 junction 接进 DSH home
#         → 写环境变量 → 建开机自启的计划任务 → 打印 NapCat 官方安装步骤与验证命令
#
# 用法（管理员或普通用户都可以，尽量不要求管理员）：
#   powershell -ExecutionPolicy Bypass -File install-host.ps1
#   powershell -ExecutionPolicy Bypass -File install-host.ps1 -Check
#   powershell -ExecutionPolicy Bypass -File install-host.ps1 -QQ 2267595782 -Port 3081
#
# 说明：本脚本在 Linux 上写的、没有 Windows 机器实测过；每一步都有验证命令，
#       失败就停在那一步并把命令打出来（详见同目录 HOST-INSTALL.md 第 3 节）。
param(
  [string]$QQ = '',
  [int]$Port = 3081,
  [int]$ConsolePort = 8798,
  [string]$DataRoot = "$env:USERPROFILE\qqbot",
  [switch]$Check,
  [switch]$NoAutostart
)
$ErrorActionPreference = 'Stop'
function Say($m)  { Write-Host "[host] $m" }
function Warn($m) { Write-Host "[host] ! $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[host] x $m" -ForegroundColor Red; exit 1 }

$DshHome   = if ($env:DSH_HOME) { $env:DSH_HOME } else { "$env:USERPROFILE\.dsh" }
$SrcDir    = Join-Path $DataRoot 'src'
$BridgeDir = Join-Path $SrcDir 'dsh-qq-onebot-bridge'
$PluginsDir= Join-Path $SrcDir 'dsh-plugins'
$Profile   = Join-Path $DshHome 'profiles\web'
$Workspace = Join-Path $DataRoot 'workspace'

Write-Host ''
Write-Host '============================================================'
Write-Host ' Windows · 不用 Docker 的安装 · 体检'
Write-Host '============================================================'
$node = Get-Command node -ErrorAction SilentlyContinue
$npm  = Get-Command npm  -ErrorAction SilentlyContinue
$git  = Get-Command git  -ErrorAction SilentlyContinue
$nodeV = if ($node) { (& node -v) } else { '无' }
$nodeOk = $false
if ($nodeV -match '^v(\d+)') { $nodeOk = [int]$Matches[1] -ge 20 }
Write-Host ("  node           : {0} {1}" -f $nodeV, $(if ($nodeOk) { '（≥20 够用）' } else { '（缺/太旧 → 用 winget 装）' }))
Write-Host ("  npm / git      : {0} / {1}" -f [bool]$npm, [bool]$git)
Write-Host ("  dsh            : {0}" -f $(if (Get-Command dsh -ErrorAction SilentlyContinue) { (& dsh --version) } else { '没有' }))
Write-Host ("  DSH home       : {0}" -f $DshHome)
Write-Host ("  数据根/工作区  : {0} / {1}" -f $DataRoot, $Workspace)
$p6700 = (Get-NetTCPConnection -LocalPort 6700 -ErrorAction SilentlyContinue)
Write-Host ("  6700 桥接端口  : {0}" -f $(if ($p6700) { '被占用（有协议端在跑？）' } else { '空' }))
Write-Host '============================================================'
if ($Check) { Say '只体检（-Check）：什么都没改'; exit 0 }

# 1) Node
if (-not $nodeOk) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Say '用 winget 装 Node LTS（用户作用域，不要求管理员）'
    winget install --id OpenJS.NodeJS.LTS --scope user --accept-source-agreements --accept-package-agreements
    Warn '装完可能需要重开一个 PowerShell 让 PATH 生效，然后重跑本脚本'
  } else {
    Warn '没有 node 也没有 winget：去 https://nodejs.org 装 LTS（勾选 Add to PATH），再重跑本脚本'
    exit 2
  }
}

# 2) dsh
Say '安装/升级 dsh（npm -g）'
& npm install -g --no-fund --no-audit '@deepseek-ai/dsh'
if (-not (Get-Command dsh -ErrorAction SilentlyContinue)) { Die '装完找不到 dsh：npm 全局 bin 不在 PATH（npm prefix -g 看看，并把它的 bin 目录加进 PATH）' }
Say ("dsh 版本：" + (& dsh --version))

# 3) 源码（没有 git 就用 codeload 下 zip 解压）
function Fetch-Repo($url, $dir) {
  if (Test-Path (Join-Path $dir '.git')) { Say "更新 $dir"; & git -C $dir pull --ff-only; return }
  if (Get-Command git -ErrorAction SilentlyContinue) { Say "clone $url"; & git clone --depth 1 $url $dir; return }
  Warn "没有 git：改用 zip 下载 $url"
  $zip = Join-Path $env:TEMP ((Split-Path $url -Leaf) + '.zip')
  $name = (Split-Path $url -Leaf) -replace '\.git$',''
  Invoke-WebRequest -Uri "https://codeload.github.com/$($url -replace '^https://github.com/','' -replace '\.git$','')/zip/refs/heads/main" -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $env:TEMP -Force
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
  Move-Item (Join-Path $env:TEMP "$name-main") $dir
  Say "解压到 $dir"
}
Fetch-Repo 'https://github.com/zfqxuz/dsh-qq-onebot-bridge.git' $BridgeDir
Fetch-Repo 'https://github.com/zfqxuz/dsh-plugins.git' $PluginsDir

# 4) 接线：junction（Windows 上的软链等价物，不需要管理员）
Say '接线：插件 → DSH home；桥接 → profile\node_modules'
New-Item -ItemType Directory -Force -Path (Join-Path $DshHome 'plugins'), (Join-Path $Profile 'node_modules'), $DataRoot | Out-Null
Get-ChildItem -Directory $PluginsDir | Where-Object { $_.Name -ne 'node_modules' } | ForEach-Object {
  $link = Join-Path (Join-Path $DshHome 'plugins') $_.Name
  if (Test-Path $link) { Remove-Item $link -Recurse -Force }
  New-Item -ItemType Junction -Path $link -Target $_.FullName | Out-Null
  Say ("  插件 junction " + $_.Name)
}
$bridgeLink = Join-Path (Join-Path $Profile 'node_modules') 'dsh-qq-onebot-bridge'
if (Test-Path $bridgeLink) { Remove-Item $bridgeLink -Recurse -Force }
New-Item -ItemType Junction -Path $bridgeLink -Target $BridgeDir | Out-Null
Say '  桥接 junction 完成'

# 5) 首启播种（只补缺、不覆盖）
$seed = Join-Path $BridgeDir 'control\bin\qq-seed.mjs'
if (Test-Path $seed) { Say '首启播种（只补缺、不覆盖已有配置）'; & node $seed }

# 6) 环境变量（用户级，重开终端生效）
Say '写用户环境变量'
[Environment]::SetEnvironmentVariable('QQ_DATA_ROOT', $DataRoot, 'User')
[Environment]::SetEnvironmentVariable('QQ_DSH_PORT', "$Port", 'User')
[Environment]::SetEnvironmentVariable('QQ_CONSOLE_PORT', "$ConsolePort", 'User')
[Environment]::SetEnvironmentVariable('QQ_ACCOUNT', $QQ, 'User')
[Environment]::SetEnvironmentVariable('QQ_WORKSPACE', $Workspace, 'User')
[Environment]::SetEnvironmentVariable('DSH_HOME', $DshHome, 'User')

# 7) 开机自启：计划任务，登录时起一个后台窗口跑 dsh web
if (-not $NoAutostart) {
  $runner = Join-Path $DataRoot 'start-dsh.cmd'
  @"
@echo off
set QQ_DATA_ROOT=$DataRoot
set DSH_HOME=$DshHome
cd /d "$Workspace"
"$(if (Get-Command dsh) { (Get-Command dsh).Source } else { 'dsh' })" web --no-open --port $Port
"@ | Set-Content -Encoding ASCII $runner
  Say "写启动器 $runner"
  schtasks /Create /TN 'qqbot-dsh-web' /SC ONLOGON /TR "cmd /c \"$runner\"" /F | Out-Null
  Say '计划任务 qqbot-dsh-web 已创建（登录时自动起；立即跑一次：schtasks /Run /TN qqbot-dsh-web）'
} else { Warn '按参数跳过自启' }

Write-Host ''
Write-Host '============================================================'
Write-Host ' 接下来（Windows）'
Write-Host '============================================================'
Write-Host '  1) 装协议端 NapCat（官方一键包，交互式，必须人工点）：'
Write-Host '     下载 NapCat.Shell.Windows.OneKey.zip（https://napneko.github.io/guide/boot/Shell 里的 Windows 一键安装）'
Write-Host '     解压后运行 NapCatInstaller.exe，完成后启动一次扫码登录'
Write-Host '     NapCat 的 OneBot11 反向 WS 目标填： ws://127.0.0.1:6700'
Write-Host '  2) 起宿主：schtasks /Run /TN qqbot-dsh-web'
Write-Host ('  3) 开网页向导： http://127.0.0.1:{0}/setup' -f $ConsolePort)
Write-Host ''
Write-Host '  验证：'
Write-Host ('    Get-NetTCPConnection -LocalPort 6700 -State Listen   # 桥接')
Write-Host ('    (Invoke-WebRequest http://127.0.0.1:{0}/login).StatusCode   # 控制台 → 200' -f $ConsolePort)
Write-Host '    Get-Process node | Select-Object Id,Path              # dsh / 控制台进程'
Write-Host ''
Write-Host '  回退：schtasks /Delete /TN qqbot-dsh-web /F'
Write-Host '        Remove-Item (Join-Path $DshHome ''plugins'') -Recurse -Force'
Write-Host '============================================================'
