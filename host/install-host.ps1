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
# [fix 2026-10-12] 用户实测：Test-Path 在某个环境变量拼出来的候选路径上抛
#   "ArgumentException: 路径中具有非法字符"，而 $ErrorActionPreference='Stop' 会让整个脚本就此终止。
# 现在一律用 .NET 的 File/Directory 存在性检查（不经过 PowerShell 的 provider 与通配符解析），
# 并且逐个 try/catch —— 探测失败最多是"没找到"，绝不让安装中断。
function Test-FileExists([string]$path) {
  if (-not $path) { return $false }
  try { return [System.IO.File]::Exists($path) } catch { return $false }
}
function Test-DirExists([string]$path) {
  if (-not $path) { return $false }
  try { return [System.IO.Directory]::Exists($path) } catch { return $false }
}
# [fix 2026-10-12] 原生命令统一走这里，别再直接写 `& git ...`。
#   坑：脚本开头设了 $ErrorActionPreference='Stop'，而 git 把进度写进 **stderr**（"Cloning into ..."）。
#   PowerShell 5.1 会把原生命令的 stderr 输出当成终止性错误 → clone 刚开头脚本就中断，日志里是
#   TerminatingError(git.exe) ... 停在 Cloning into '...'（用户 2026-10-12 真机踩到）。
#   这里临时把偏好设回 Continue，只按退出码判断成败；输出照常打进日志。
function Invoke-Native {
  param([string]$Exe, [string[]]$Argv, [switch]$Quiet)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($Quiet) { & $Exe @Argv 2>&1 | Out-Null }
    else { & $Exe @Argv 2>&1 | ForEach-Object { Write-Host ([string]$_) } }
    return $LASTEXITCODE
  } catch {
    Warn "$Exe 调用异常：$($_.Exception.Message)"
    return 1
  } finally {
    $ErrorActionPreference = $prev
  }
}
function Find-Exe([string]$name, [string[]]$extraDirs) {
  $c = Get-Command $name -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($d in $extraDirs) {
    if (-not $d) { continue }
    $base = ([string]$d).Trim().TrimEnd('\', '/')
    if (-not $base) { continue }
    foreach ($leaf in @($name, "$name.cmd", "$name.exe")) {
      $cand = $base + '\' + $leaf
      if (Test-FileExists $cand) { return $cand }
    }
  }
  return $null
}
function Get-ExistingDirs([string[]]$dirs) {
  $out = @()
  foreach ($d in $dirs) { if ($d -and (Test-DirExists ([string]$d).Trim())) { $out += ([string]$d).Trim() } }
  return $out
}
$nodeDirs = @(
  (Join-Path $env:ProgramFiles 'nodejs'),
  $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'nodejs' }),
  (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'),
  (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
  (Join-Path $env:APPDATA 'nvm\current')
)
$npmDirs = $nodeDirs + @((Join-Path $env:APPDATA 'npm'), (Join-Path $env:LOCALAPPDATA 'pnpm'))
$foundExe = @((Find-Exe 'node' $nodeDirs), (Find-Exe 'npm' $npmDirs), (Find-Exe 'dsh' $npmDirs))
$foundDirs = @($foundExe | Where-Object { $_ } | ForEach-Object { Split-Path -Parent $_ } | Select-Object -Unique)
if ($foundDirs.Count -gt 0) { $env:Path = ($foundDirs -join ';') + ';' + $env:Path }

# [fix 2026-10-12] node/npm 的统一解析：**按版本挑最高的那份，不看 PATH 顺序**
#   为什么必须这样：Windows 的 PATH = 系统 PATH + 用户 PATH（系统在前），所以 winget 装到
#   用户作用域的 Node 24 永远被 C:\Program Files\nodejs 里的旧 Node（v16/v20）压住。
#   旧实现在 PATH 上找 node → 装完 Node 24 仍然解析成 v20 → 脚本自己 Die（真机 2026-10-12 踩到）。
#   现在把候选目录逐个看，拿版本号决胜；后面所有调用（npm 安装、启动器）都用解析出来的绝对路径。
function Resolve-NodeState {
  $best = $null; $bestV = $null
  $cands = @()
  foreach ($d in $nodeDirs) {
    if (-not $d) { continue }
    $base = ([string]$d).Trim().TrimEnd('\', '/')
    if (-not $base) { continue }
    foreach ($leaf in @('node.exe', 'node')) {
      $p = $base + '\' + $leaf
      if (Test-FileExists $p) { $cands += $p }
    }
  }
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { $cands += $cmd.Source }
  foreach ($p in ($cands | Select-Object -Unique)) {
    try { $v = (& $p -v) } catch { continue }
    if ($v -notmatch '^v(\d+)\.(\d+)\.(\d+)') { continue }
    $key = [version]$v.TrimStart('v')
    if ((-not $bestV) -or ($key -gt $bestV)) { $bestV = $key; $best = $p }
  }
  $script:nodePath = $best
  $script:node = if ($best) { [pscustomobject]@{ Source = $best } } else { $null }
  $script:nodeV = if ($best) { (& $best -v) } else { '无' }
  $script:nodeOk = $false
  if ($script:nodeV -match '^v(\d+)\.(\d+)') {
    $script:nodeOk = ([int]$Matches[1] -gt 22) -or ([int]$Matches[1] -eq 22 -and [int]$Matches[2] -ge 13)
  }
  # npm 跟 node 同目录（同一个安装里必带），找不到再退回原来的搜法
  $script:npmPath = $null
  if ($best) {
    $dir = Split-Path -Parent $best
    foreach ($leaf in @('npm.cmd', 'npm')) {
      $p = Join-Path $dir $leaf
      if (Test-FileExists $p) { $script:npmPath = $p; Break }
    }
  }
  if (-not $script:npmPath) { $script:npmPath = Find-Exe 'npm' $npmDirs }
  $script:npm = if ($script:npmPath) { [pscustomobject]@{ Source = $script:npmPath } } else { $null }
}

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
$git  = Get-Command git  -ErrorAction SilentlyContinue
# node/npm：按版本挑最高的那份（门槛 ≥22.13，插件静态 import 'node:sqlite'）
Resolve-NodeState
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
if (-not $nodeOk) {
  # 兜底：不依赖 winget、也不需要管理员 —— 下官方 zip 解到 %LOCALAPPDATA%\Programs\nodejs
  function Install-NodeFromZip {
    $ver = if ($env:QQ_NODE_VERSION) { $env:QQ_NODE_VERSION } else { 'v22.14.0' }
    $mirror = if ($env:QQ_NODE_MIRROR) { $env:QQ_NODE_MIRROR.TrimEnd('/') } else { 'https://nodejs.org/dist' }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $url = "$mirror/$ver/node-$ver-win-$arch.zip"
    $zip = Join-Path $env:TEMP "node-$ver-win-$arch.zip"
    $dest = Join-Path $env:LOCALAPPDATA 'Programs\nodejs'
    Say "下载 $url"
    try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip } catch { Warn "下载失败：$($_.Exception.Message)"; return $false }
    $tmp = Join-Path $env:TEMP ('node-unzip-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
      Expand-Archive -Path $zip -DestinationPath $tmp -Force
      $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
      if (-not $inner) { Warn '解压结果不对（没有顶层目录）'; return $false }
      if (Test-DirExists $dest) { Remove-Item -Recurse -Force $dest }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
      Move-Item $inner.FullName $dest
    } catch { Warn "解压/安装失败：$($_.Exception.Message)"; return $false }
    finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue; Remove-Item -Force $zip -ErrorAction SilentlyContinue }
    Say "Node 已解到 $dest"
    return $true
  }

  $wingetOk = $false
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Say "node 是 $nodeV（需要 ≥22.13）→ 用 winget 装 Node LTS"
    # 先试用户作用域（不需要管理员）；Node 的 winget 包不一定支持 --scope user，失败就回退默认作用域（可能弹 UAC）
    $wgRc = Invoke-Native 'winget' @('install', '--id', 'OpenJS.NodeJS.LTS', '--scope', 'user', '--accept-source-agreements', '--accept-package-agreements')
    if ($wgRc -ne 0) {
      Warn "用户作用域安装失败（winget 退出码 $wgRc）→ 改试默认作用域（可能弹管理员确认）"
      $wgRc = Invoke-Native 'winget' @('install', '--id', 'OpenJS.NodeJS.LTS', '--accept-source-agreements', '--accept-package-agreements')
    }
    if ($wgRc -eq 0) { $wingetOk = $true } else { Warn "winget 两次都没成功（最后一次退出码 $wgRc）→ 改用官方 zip" }
  } else {
    Warn '这台机器上没有 winget → 改用官方 zip 安装（不需要管理员）'
  }
  if (-not $wingetOk) { [void](Install-NodeFromZip) }

  # 新装的 Node 目录可能排在旧版后面 → 显式前置，再重新解析
  $freshDirs = Get-ExistingDirs @(
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
    (Join-Path $env:ProgramFiles 'nodejs')
  )
  if ($freshDirs) { $env:Path = (($freshDirs | Select-Object -Unique) -join ';') + ';' + $env:Path }
  Resolve-NodeState
  if ($nodeOk) {
    $pathNode = (Get-Command node -ErrorAction SilentlyContinue).Source
    if ($pathNode -and ($pathNode -ne $nodePath)) {
      Warn "PATH 里的 node 仍是旧版：$pathNode（本次安装一律用 $nodePath，$nodeV —— 启动器里写的就是绝对路径）"
      Warn '想让命令行也用它：把旧 Node 目录从系统 PATH 里去掉，或卸载旧版 Node（控制台/设置 → 应用）'
    }
  }
  if (-not $nodeOk) {
    Die "装完 node 还是 $nodeV（需要 ≥22.13）。多半是旧 Node 排在 PATH 前面：
      · 现在用的是 $nodePath
      · 把上面那个目录从用户/系统 PATH 里删掉，或先卸载旧版 Node，然后重跑本脚本
      · 验证：新开一个 PowerShell，node -v 应该 ≥ v22.13
      · 也可以自己设镜像再跑：QQ_NODE_MIRROR=https://npmmirror.com/mirrors/node"
  }
}

# 1.6) 代理：环境里有 HTTPS_PROXY 就自动给 git 用（不写进你的全局配置，只在本次命令上加 -c）
$script:proxyEnv = ''
if ($env:HTTPS_PROXY) { $script:proxyEnv = $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $script:proxyEnv = $env:HTTP_PROXY }
if ($script:proxyEnv) { Say "检测到代理，git 会走它：$script:proxyEnv" }
# 1.5) 把 npm 全局 bin 目录前置：`npm i -g` 装的 dsh 落在那里，本会话的 PATH 里可能还没有
if ($npmPath) {
  try {
    $npmPrefix = (& $npmPath prefix -g 2>$null | Select-Object -First 1)
    if ((Test-DirExists ([string]$npmPrefix).Trim()) -and ($env:Path -notlike "*$npmPrefix*")) {
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
  $npmRc = Invoke-Native $npmPath @('install', '-g', '--no-fund', '--no-audit', "@deepseek-ai/dsh$dshSpec")
  if ($npmRc -ne 0) { Die "npm 安装 dsh 失败（退出码 $npmRc），先修好网络/权限再重跑" }
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
  $gp = @()
  if ($script:proxyEnv) { $gp = @('-c', "http.proxy=$script:proxyEnv", '-c', "https.proxy=$script:proxyEnv") }
  if (Test-FileExists (Join-Path $dir '.git')) {
    Say "更新 $dir"
    $rc = Invoke-Native 'git' (@('-C', $dir) + $gp + @('pull', '--ff-only'))
    if ($rc -ne 0) { Warn "更新失败：$dir（网络问题或本地有改动）" }
    return
  }
  if (Get-Command git -ErrorAction SilentlyContinue) {
    Say "clone $url"
    $rc = Invoke-Native 'git' ($gp + @('clone', '--depth', '1', $url, $dir))
    if ($rc -ne 0) {
      Warn "git clone 失败：$url"
      Warn '  连不上 GitHub 的话，配一次代理再重跑（端口换成你自己的）：'
      Warn '    git config --global http.proxy http://127.0.0.1:7890'
      Warn '    git config --global https.proxy http://127.0.0.1:7890'
      Warn '  （环境变量 HTTPS_PROXY 已有的话，本脚本会自动用它）'
      return
    }
    return
  }
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
if (Test-Path $seed) { Say '首启播种（只补缺、不覆盖已有配置）'; $null = Invoke-Native $nodePath @($seed, '--data-root', $DataRoot) }

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

# 8) 开机自启：两个计划任务（dsh web + 控制台），并且**立刻起来**（不等下次登录）
if (-not $NoAutostart) {
  $runner = Join-Path $DataRoot 'start-dsh.cmd'
  @"
@echo off
set QQ_DATA_ROOT=$DataRoot
set DSH_HOME=$DshHome
cd /d "$Workspace"
"$nodePath" "$runnerJs" --port $Port --data-root "$DataRoot" -- "$(if (Get-Command dsh) { (Get-Command dsh).Source } else { 'dsh' })" web --no-open --port $Port
"@ | Set-Content -Encoding ASCII $runner
  Say "写启动器 $runner"
  # 注意：PowerShell 里没有 \" 转义，/TR 的值用拼接构造成 cmd /c "<路径>"
  $trDsh = 'cmd /c "' + $runner + '"'
  $null = Invoke-Native 'schtasks' @('/Create', '/TN', 'qqbot-dsh-web', '/SC', 'ONLOGON', '/TR', $trDsh, '/F') -Quiet
  Say '计划任务 qqbot-dsh-web 已创建（登录时自动起）'

  # 控制台（127.0.0.1:8798）：Docker 里它是独立容器、Linux 是 systemd 单元，Windows 原先漏了这个入口 ——
  # 装完打不开控制台（2026-10-12 补）。跟 dsh web 一样注册一个登录自启任务。
  $consoleJs = Join-Path $BridgeDir 'control\bin\qq-acl-console.mjs'
  if (Test-Path $consoleJs) {
    $consoleRunner = Join-Path $DataRoot 'start-console.cmd'
    @"
@echo off
set QQ_DATA_ROOT=$DataRoot
set DSH_HOME=$DshHome
cd /d "$Workspace"
"$nodePath" "$consoleJs" --port $ConsolePort --data-root "$DataRoot"
"@ | Set-Content -Encoding ASCII $consoleRunner
    Say "写控制台启动器 $consoleRunner"
    $trConsole = 'cmd /c "' + $consoleRunner + '"'
    $null = Invoke-Native 'schtasks' @('/Create', '/TN', 'qqbot-console', '/SC', 'ONLOGON', '/TR', $trConsole, '/F') -Quiet
    Say '计划任务 qqbot-console 已创建（登录时自动起）'
  } else {
    Warn "找不到 $consoleJs：跳过控制台自启（控制台可手工跑）"
  }

  # 立刻跑一次这两个任务，并等端口真的起来 —— 安装器就是等这里跑完才去开浏览器
  # [fix 2026-10-12] 上限 90 → 180 秒：控制台第一次启动时如果权限库还没建好，它会先等桥接建库
  #   （最多 120 秒，见 qq-acl-console.mjs）。90 秒会在慢机器上误判成失败。
  foreach ($tn in @('qqbot-dsh-web', 'qqbot-console')) { $null = Invoke-Native 'schtasks' @('/Run', '/TN', $tn) -Quiet }
  Say "已触发启动，等端口就绪（最多 180 秒）…"
  $deadline = (Get-Date).AddSeconds(180)
  $ready = $false
  $okDsh = $false; $okConsole = $false
  while ((Get-Date) -lt $deadline) {
    $okDsh = $false; $okConsole = $false
    try { $okDsh = (New-Object Net.Sockets.TcpClient).ConnectAsync('127.0.0.1', $Port).Wait(800) } catch { }
    try { $okConsole = (New-Object Net.Sockets.TcpClient).ConnectAsync('127.0.0.1', $ConsolePort).Wait(800) } catch { }
    if ($okDsh -and $okConsole) { $ready = $true; break }
    Start-Sleep -Milliseconds 1000
  }
  if ($ready) {
    Say "宿主与控制台已就绪：http://127.0.0.1:$ConsolePort/"
  } else {
    # [fix 2026-10-12] 没起来就**算失败**（退出码 1）：安装器完成页据此显示"失败 + 日志尾部"。
    #   旧实现在这里只 Warn 然后 exit 0 —— 向导照样写"安装完成，控制台已打开"，用户点了是打不开的
    #   （2026-10-12 真机踩到：8798 ERR_CONNECTION_REFUSED，向导却报成功）。
    $aclDb = Join-Path $DataRoot 'configacl.db'
    Warn ("宿主/控制台没起来：宿主 $Port = " + $(if ($okDsh) { '在' } else { '没在' }) + '，控制台 ' + $ConsolePort + ' = ' + $(if ($okConsole) { '在' } else { '没在' }))
    Warn ("权限库 " + $aclDb + "：" + $(if (Test-Path $aclDb) { '存在' } else { '缺失' }))
    Warn ("控制台启动器 " + (Join-Path $DataRoot 'start-console.cmd') + "：" + $(if (Test-Path (Join-Path $DataRoot 'start-console.cmd')) { '存在' } else { '缺失（拉源码那步可能没成功）' }))
    Warn '手工跑一次控制台看具体报错（窗口会留着）：cmd /k "%USERPROFILE%qqbotstart-console.cmd"'
    Die "装完了但服务没起来（$Port / $ConsolePort 连不上）：按上面几行排查；权限库缺失的话重跑本脚本会自动补"
  }
} else { Warn '按参数跳过自启' }

Write-Host ''
Write-Host '下一步：装 NapCat（官方一键包，人工点）'
Write-Host '  https://napneko.github.io/guide/boot/Shell → NapCat.Shell.Windows.OneKey.zip → NapCatInstaller.exe'
Write-Host '  NapCat 里 OneBot11 反向 WS 填 ws://127.0.0.1:6700，然后扫码登录'
Write-Host ''
Write-Host ("控制台：http://127.0.0.1:{0}/setup" -f $ConsolePort)
Write-Host '起宿主：schtasks /Run /TN qqbot-dsh-web    停：schtasks /End /TN qqbot-dsh-web'
Write-Host '卸载：开始菜单 → 卸载（保留数据）'
Stop-Log
if ($LogFile) { Write-Host ''; Write-Host "日志：$LogFile" }
Pause-Here
