# install-host.ps1 —— Windows 上的"不用 Docker"安装
#
# 做什么：按分层装 Node（缺则用 winget）→ 按分层装 dsh → 拉桥接/插件源码 → 用 junction 接进 DSH home
#         → 写环境变量 → 建开机自启的计划任务 → 打印 NapCat 官方安装步骤与验证命令
#
# 分层：已有的东西一律不动 —— 有 Node 不装 Node，有 dsh 不装 dsh（要升级显式加 -UpgradeDsh）
#
# 用法（管理员或普通用户都可以，尽量不要求管理员）：
#   powershell -ExecutionPolicy Bypass -File install-host.ps1
#   powershell -ExecutionPolicy Bypass -File install-host.ps1 -Check
#   powershell -ExecutionPolicy Bypass -File install-host.ps1 -QQ 2267595782 -Port 3081
#   powershell -ExecutionPolicy Bypass -File install-host.ps1 -UpgradeDsh
#   powershell -ExecutionPolicy Bypass -File install-host.ps1 -DshVersion 0.2.0-rc.2
#   powershell -ExecutionPolicy Bypass -File install-host.ps1 -SkipDsh
#
# 说明：本脚本在 Linux 上写的、没有 Windows 机器实测过；每一步都有验证命令，
#       失败就停在那一步并把命令打出来（详见同目录 HOST-INSTALL.md 第 3 节）。
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
  [switch]$NoPause     # 由别的脚本调用时加；双击/安装器启动时默认会停住等回车（避免报错一闪而过）
)
$ErrorActionPreference = 'Stop'

# ---------- 0) 刷新 PATH + 记录日志（Windows 两个经典坑，2026-10-12 用户实测踩到）----------
# 坑 1：安装器/快捷方式启动的进程可能拿着"旧的" PATH —— 刚装好的 Node/dsh 看不见，
#       脚本就会说"没有 npm"然后退出，窗口一闪而过。这里从注册表重新拼一遍 PATH。
$machPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($machPath -or $userPath) { $env:Path = (@($machPath, $userPath) | Where-Object { $_ }) -join ';' }

# 坑 2：双击运行时窗口关了就没法看报错。这里从头记 transcript，失败也留一份。
$LogFile = ''
try {
  New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
  $LogFile = Join-Path $DataRoot ('install-log-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
  Start-Transcript -Path $LogFile -Force | Out-Null
} catch { $LogFile = '' }

function Say($m)  { Write-Host "[host] $m" }
function Warn($m) { Write-Host "[host] ! $m" -ForegroundColor Yellow }
function Stop-Log { if ($LogFile) { try { Stop-Transcript | Out-Null } catch { } } }
function Pause-Here {
  if ($NoPause) { return }
  try { if ([Environment]::UserInteractive) { Write-Host ''; Read-Host '按回车关闭这个窗口' | Out-Null } } catch { }
}
function Die($m) {
  Write-Host "[host] x $m" -ForegroundColor Red
  if ($LogFile) { Write-Host "[host] 完整日志：$LogFile" }
  Stop-Log
  Pause-Here
  exit 1
}

# ---------- 0.5) 找不到就找常见安装位置（PATH 没生效也能救）----------
function Find-Exe([string]$name, [string[]]$extraDirs) {
  $c = Get-Command $name -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $cands = @()
  foreach ($d in $extraDirs) { if ($d) { $cands += (Join-Path $d $name); $cands += (Join-Path $d "$name.cmd"); $cands += (Join-Path $d "$name.exe") } }
  foreach ($p in $cands) { if ($p -and (Test-Path $p)) { return $p } }
  return $null
}
$nodeDirs = @(
  (Join-Path $env:ProgramFiles 'nodejs'),
  $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'nodejs' }),
  (Join-Path $env:LOCALAPPDATA 'Programs
odejs'),
  (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
  (Join-Path $env:APPDATA 'nvm\current')
)
$npmDirs = $nodeDirs + @((Join-Path $env:APPDATA 'npm'), (Join-Path $env:LOCALAPPDATA 'pnpm'))
$foundExe = @((Find-Exe 'node' $nodeDirs), (Find-Exe 'npm' $npmDirs), (Find-Exe 'dsh' $npmDirs))
$foundDirs = @($foundExe | Where-Object { $_ } | ForEach-Object { Split-Path -Parent $_ } | Select-Object -Unique)
if ($foundDirs.Count -gt 0) { $env:Path = ($foundDirs -join ';') + ';' + $env:Path }

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
# [fix 2026-10-12] 门槛是 ≥22.13：插件静态 import 'node:sqlite'（20.x 直接抛错，22.5~22.12 要 flag）
$nodeOk = $false
if ($nodeV -match '^v(\d+)\.(\d+)') { $nodeOk = ([int]$Matches[1] -gt 22) -or ([int]$Matches[1] -eq 22 -and [int]$Matches[2] -ge 13) }
Write-Host ("  node           : {0} {1}" -f $nodeV, $(if ($nodeOk) { '（≥22.13 够用）' } else { '（缺/太旧：需要 ≥22.13 → 用 winget 装）' }))
Write-Host ("  npm / git      : {0} / {1}" -f [bool]$npm, [bool]$git)
Write-Host ("  dsh            : {0}" -f $(if (Get-Command dsh -ErrorAction SilentlyContinue) { "$(& dsh --version)（在，默认不动）" } else { '没有 → 会装' }))
Write-Host ("  DSH home       : {0}" -f $DshHome)
Write-Host ("  数据根/工作区  : {0} / {1}" -f $DataRoot, $Workspace)
$p6700 = $null; if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) { try { $p6700 = Get-NetTCPConnection -LocalPort 6700 -ErrorAction SilentlyContinue } catch { } }
Write-Host ("  6700 桥接端口  : {0}" -f $(if ($p6700) { '被占用（有协议端在跑？）' } else { '空' }))
Write-Host '============================================================'
if ($Check) { Say '只体检（-Check）：什么都没改'; if ($LogFile) { Say "本次日志：$LogFile" }; Stop-Log; Pause-Here; exit 0 }

# 1) Node（缺或太旧 → winget 装；装完必须**重新解析**，否则会继续用旧的 v16）
function Resolve-NodeState {
  $np = Find-Exe 'node' $nodeDirs
  $mp = Find-Exe 'npm'  $npmDirs
  $script:nodePath = $np
  $script:npmPath  = $mp
  # 后面别处用 $node.Source / $npm.Source，这里包一层保持形状一致
  $script:node = if ($np) { [pscustomobject]@{ Source = $np } } else { $null }
  $script:npm  = if ($mp) { [pscustomobject]@{ Source = $mp } } else { $null }
  $script:nodeV = if ($np) { (& $np -v) } else { '无' }
  $script:nodeOk = $false
  if ($script:nodeV -match '^v(\d+)\.(\d+)') {
    $script:nodeOk = ([int]$Matches[1] -gt 22) -or ([int]$Matches[1] -eq 22 -and [int]$Matches[2] -ge 13)
  }
}
if (-not $nodeOk) {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Die "node 是 $nodeV（需要 ≥22.13），而这台机器上没有 winget。两条路：
      1) 去 https://nodejs.org 下 LTS 的 .msi 装上（安装时勾 Add to PATH），再重跑本脚本
      2) 从 Microsoft Store 装「应用安装程序」拿到 winget，再重跑本脚本"
  }
  Say "node 是 $nodeV（需要 ≥22.13）→ 用 winget 装 Node LTS"
  # 先试用户作用域（不需要管理员）；Node 的 winget 包不一定支持 --scope user，失败就回退默认作用域（可能弹 UAC）
  & winget install --id OpenJS.NodeJS.LTS --scope user --accept-source-agreements --accept-package-agreements
  if ($LASTEXITCODE -ne 0) {
    Warn "用户作用域安装失败（winget 退出码 $LASTEXITCODE）→ 改试默认作用域（可能弹管理员确认）"
    & winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
  }
  # 新装的 Node 目录可能排在旧 v16 后面 → 显式前置，再重新解析
  $freshDirs = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
    (Join-Path $env:ProgramFiles 'nodejs')
  ) | Where-Object { $_ -and (Test-Path $_) }
  if ($freshDirs) { $env:Path = (($freshDirs | Select-Object -Unique) -join ';') + ';' + $env:Path }
  Resolve-NodeState
  if (-not $nodeOk) {
    Die "装完 node 还是 $nodeV（需要 ≥22.13）。多半是旧 Node 排在 PATH 前面：
      · 现在用的是 $nodePath
      · 把上面那个目录从用户/系统 PATH 里删掉，或先卸载旧版 Node，然后重跑本脚本
      · 验证：新开一个 PowerShell，node -v 应该 ≥ v22.13"
  }
  Say "node 就绪：$nodeV（$nodePath）"
}

# 1.5) 把 npm 全局 bin 目录前置：`npm i -g` 装的 dsh 落在那里，本会话的 PATH 里可能还没有
if ($npmPath) {
  try {
    $npmPrefix = (& $npmPath prefix -g 2>$null | Select-Object -First 1)
    if ($npmPrefix -and (Test-Path $npmPrefix) -and ($env:Path -notlike "*$npmPrefix*")) {
      $env:Path = "$npmPrefix;$env:Path"
      Say "PATH 前置 npm 全局目录：$npmPrefix"
    }
  } catch { }
}

# 2) dsh（分层：有就不动，缺才装，点名才换）
# 与 Node 一个原则：不擅自升级用户机器上已有的 dsh。
# 插件声明的兼容范围是 0.1.x / 0.2.x（见 package.json 的 peerDependencies）。
function Test-DshVerOk($v) { return ($v -match '^0\.(1|2)\.') }
$dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
$dshNow = if ($dshCmd) { ((& dsh --version) -replace '\s', '') } else { '' }
$needDsh = $false; $dshWhy = ''
if ($SkipDsh) {
  if (-not $dshCmd) { Die '-SkipDsh 但机器上没有 dsh（想让脚本装就别加这个参数）' }
  $dshWhy = '按 -SkipDsh 不动它'
} elseif ($DshVersion -ne '') {
  if ($dshNow -eq $DshVersion -or $dshNow -eq $DshVersion.TrimStart('v')) { $dshWhy = "已经是要的版本 $dshNow，跳过" }
  else { $needDsh = $true; $dshWhy = "按 -DshVersion $DshVersion 安装（现有：$(if ($dshNow) { $dshNow } else { '无' })）" }
} elseif ($UpgradeDsh) {
  $needDsh = $true; $dshWhy = "按 -UpgradeDsh 升级（现有：$(if ($dshNow) { $dshNow } else { '无' })）"
} elseif (-not $dshCmd) {
  $needDsh = $true; $dshWhy = '机器上没有 dsh，装一个'
} else {
  $dshWhy = "已有 dsh $dshNow，跳过（要升级：-UpgradeDsh）"
}
if ($needDsh) {
  if (-not $npmPath) { Die '没有 npm：先装好 Node ≥22.13 再重跑（见上面 node 那一节）' }
  $dshSpec = if ($DshVersion) { "@$DshVersion" } else { '' }
  Say "安装 @deepseek-ai/dsh$dshSpec（$dshWhy）"
  & npm install -g --no-fund --no-audit "@deepseek-ai/dsh$dshSpec"
  $dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
  if (-not $dshCmd) { Die '装完找不到 dsh：npm 全局 bin 不在 PATH（npm prefix -g 看看，并把它的 bin 目录加进 PATH）' }
  $dshNow = ((& dsh --version) -replace '\s', '')
}
Say "dsh：$($dshCmd.Source)（$dshNow）— $dshWhy"
Say "node：$($node.Source)（$nodeV）"
if (-not (Test-DshVerOk $dshNow)) {
  Warn "dsh $dshNow 不在插件声明的兼容范围（0.1.x / 0.2.x）内，插件可能加载不了。要换版本：install-host.ps1 -DshVersion 0.2.0-rc.2（脚本默认不动你现有的 dsh）"
}

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

# 7) 装 dsh 启动器（登记真实地址，控制台据此自发现端口；四种部署方式共用同一份实现）
$binDir = Join-Path $DataRoot 'bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$runnerJs = Join-Path $binDir 'dsh-web-run.mjs'
$runnerSrc = Join-Path $PSScriptRoot '..\dsh-web-run.mjs'
if (Test-Path $runnerSrc) { Copy-Item $runnerSrc $runnerJs -Force; Say "装 dsh 启动器 → $runnerJs" }
else { Warn "没找到 $runnerSrc：跳过启动器（控制台改用环境变量找端口）" }

# 8) 开机自启：计划任务，登录时起一个后台窗口跑 dsh web
if (-not $NoAutostart) {
  $runner = Join-Path $DataRoot 'start-dsh.cmd'
  @"
@echo off
set QQ_DATA_ROOT=$DataRoot
set DSH_HOME=$DshHome
cd /d "$Workspace"
node "$runnerJs" --port $Port --data-root "$DataRoot" -- "$(if (Get-Command dsh) { (Get-Command dsh).Source } else { 'dsh' })" web --no-open --port $Port
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
Stop-Log
if ($LogFile) { Write-Host "[host] 本次日志：$LogFile" }
Pause-Here
Write-Host '        Remove-Item (Join-Path $DshHome ''plugins'') -Recurse -Force'
Write-Host '============================================================'
