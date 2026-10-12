# ============================================================
#  update-host.ps1 —— Windows 宿主模式（不用 Docker）的更新
#
#  就地更新，不动数据：
#    ① 部署包本身（git 检出时 git pull；解压包用 -Refresh 重下）
#    ② 桥接与插件源码（$DataRoot\src 下的 git 仓库，ff-only）
#    ③ 插件（如果 profile 里是从 npm 装的，走 pnpm update）
#  然后重跑首启播种（只补缺）+ 重启计划任务。
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File update-host.ps1
#    powershell -ExecutionPolicy Bypass -File update-host.ps1 -Check
#    powershell -ExecutionPolicy Bypass -File update-host.ps1 -DryRun
#    powershell -ExecutionPolicy Bypass -File update-host.ps1 -NoRestart
# ============================================================
param(
  [string]$DataRoot = '',
  [string]$DshHome = '',
  [switch]$Check,
  [switch]$DryRun,
  [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
function Say($m) { Write-Host "[update-host] $m" }
function Warn($m) { Write-Host "[update-host] ! $m" -ForegroundColor Yellow }
function RunIt($desc, [scriptblock]$sb) {
  if ($DryRun) { Say "（干跑）$desc" ; return }
  Say $desc
  try { & $sb } catch { Warn "失败：$($_.Exception.Message)" }
}

$EnvFile = Join-Path $env:USERPROFILE '.config\dsh-bot\dsh.env'
# ⚠️ 破坏性/关键路径只认显式参数 → 安装记录 → 默认值，绝不从环境变量取
$env:QQ_DATA_ROOT = $null; $env:DSH_HOME = $null
$fromFile = @{}
if (Test-Path $EnvFile) {
  Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $fromFile[$Matches[1]] = $Matches[2].Trim() }
  }
}
if (-not $DataRoot) { $DataRoot = if ($fromFile['QQ_DATA_ROOT']) { $fromFile['QQ_DATA_ROOT'] } else { Join-Path $env:USERPROFILE 'qqbot' } }
if (-not $DshHome) { $DshHome = if ($fromFile['DSH_HOME']) { $fromFile['DSH_HOME'] } else { Join-Path $env:USERPROFILE '.dsh' } }
$BridgeDir = Join-Path $DataRoot 'src\dsh-qq-onebot-bridge'
$PluginsDir = Join-Path $DataRoot 'src\dsh-plugins'
$ProfileDir = Join-Path $DshHome 'profiles\web'
$RunnerJs = Join-Path $DataRoot 'bin\dsh-web-run.mjs'
$RunnerSrc = Join-Path $PSScriptRoot '..\dsh-web-run.mjs'

function LocalVer($dir) {
  $pj = Join-Path $dir 'package.json'
  if (-not (Test-Path $pj)) { return '' }
  try { return (Get-Content $pj -Raw | ConvertFrom-Json).version } catch { return '' }
}
function NpmLatest($name) {
  try { return ((& npm view --prefer-online $name version 2>$null) | Select-Object -Last 1) } catch { return '' }
}

Say "数据根：$DataRoot"
Say "桥接源码版本：$(if (LocalVer $BridgeDir) { LocalVer $BridgeDir } else { '（没装/没读出来）' })"
Say "插件 npm 最新：$(if (NpmLatest '@zfqxuz/dsh-qq-onebot-bridge') { NpmLatest '@zfqxuz/dsh-qq-onebot-bridge' } else { '（查不到，离线？）' })"
if ($Check) { Say '只检查（-Check）：什么都没改。要更新：不加 -Check 重跑'; exit 0 }

# ① 部署包自己
$pkgRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (Test-Path (Join-Path $pkgRoot '.git')) {
  RunIt '部署包：git pull --ff-only' { git -C $pkgRoot pull --ff-only }
} else {
  Warn '当前不是 git 检出的部署包（解压/下载的）：要更新请重跑 get-qqbot.ps1 并加 -Refresh'
}

# ② 源码
foreach ($d in @($BridgeDir, $PluginsDir)) {
  if (Test-Path (Join-Path $d '.git')) { RunIt "更新源码：$d" { git -C $d pull --ff-only } }
  else { Warn "不是 git 仓库，跳过：$d" }
}

# ③ 插件（npm 装的才走这条）
$profPkg = Join-Path $ProfileDir 'package.json'
if ((Test-Path $profPkg) -and ((Get-Content $profPkg -Raw) -match '@zfqxuz/dsh-qq-onebot-bridge')) {
  RunIt '插件是 npm 装的：pnpm update' { dsh plugin --profile web update '@zfqxuz/dsh-qq-onebot-bridge' }
} else {
  Say '插件是本地目录junction装的：源码已更新（上面 ②），不用 npm 更新'
}

# 启动器 / 播种
if (Test-Path $RunnerSrc) { RunIt "刷新 dsh 启动器 → $RunnerJs" { Copy-Item $RunnerSrc $RunnerJs -Force } }
$seed = Join-Path $BridgeDir 'control\bin\qq-seed.mjs'
if (Test-Path $seed) { RunIt '重新播种（只补缺）' { & node $seed } }

# 重启计划任务
if ($NoRestart) { Say '按参数不重启（-NoRestart）' }
elseif (Get-ScheduledTask -TaskName 'qqbot-dsh-web' -ErrorAction SilentlyContinue) {
  RunIt '重启计划任务 qqbot-dsh-web' { schtasks /End /TN 'qqbot-dsh-web' | Out-Null; schtasks /Run /TN 'qqbot-dsh-web' | Out-Null }
} else { Warn '没有计划任务 qqbot-dsh-web：如果你是手动起的 dsh，自己重启它' }

if (-not $DryRun) {
  Start-Sleep -Seconds 3
  foreach ($p in @(3080, 3081)) {
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
      Say "DSH 在 $p 上有响应（HTTP $($r.StatusCode)）"
    } catch {
      if ($_.Exception.Response) { Say "DSH 在 $p 上有响应（HTTP $([int]$_.Exception.Response.StatusCode)）" }
    }
  }
  Say '更新完成。桥接会话/数据都在数据根里，没被碰过'
}
