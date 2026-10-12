# ============================================================
#  uninstall-host.ps1 —— Windows 宿主模式（不用 Docker）的卸载
#
#  默认卸载"我们装的东西"，**保留你的数据**：
#    停掉并删除计划任务 qqbot-dsh-web、删除 start-dsh.cmd 与 dsh 启动器
#    删掉 DSH home 里我们建的 junction/软链（只删指向 $DataRoot\src 的）
#    从 profile 配置里移除桥接挂载声明（改前备份）
#    清理安装时写的用户环境变量
#    删掉 $DataRoot\src 下的源码
#
#  不碰：Node、dsh（npm 全局）、NapCat、DSH home 本身、数据根（除非 -Purge）
#
#  用法：
#    ... -File uninstall-host.ps1 -DryRun          先看它要删什么
#    ... -File uninstall-host.ps1                  真卸（数据留着）
#    ... -File uninstall-host.ps1 -KeepSources     源码也留着
#    ... -File uninstall-host.ps1 -Purge -Yes      连数据根一起删
# ============================================================
param(
  [string]$DataRoot = '',
  [string]$DshHome = '',
  [switch]$DryRun,
  [switch]$Purge,
  [switch]$Yes,
  [switch]$KeepSources,
  [switch]$KeepProfileConfig
)
$ErrorActionPreference = 'Continue'
function Say($m) { Write-Host "[uninstall-host] $m" }
function Warn($m) { Write-Host "[uninstall-host] ! $m" -ForegroundColor Yellow }
function RunIt($desc, [scriptblock]$sb) {
  if ($DryRun) { Say "（干跑）$desc"; return }
  Say $desc
  try { & $sb } catch { Warn "失败：$($_.Exception.Message)" }
}

$EnvFile = Join-Path $env:USERPROFILE '.config\dsh-bot\dsh.env'
# ⚠️ 破坏性操作：数据根/DSH home 只认显式参数 → 安装记录 → 默认值，绝不从环境变量取
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
$PluginLinks = Join-Path $DshHome 'plugins'

Say "要卸载的部署：数据根 $DataRoot · DSH home $DshHome"
if ($DryRun) { Say '干跑模式：下面只打印，不执行' }

# ---------- 1) 计划任务 + 启动器 ----------
$task = Get-ScheduledTask -TaskName 'qqbot-dsh-web' -ErrorAction SilentlyContinue
if ($task) {
  RunIt '删除计划任务 qqbot-dsh-web' { schtasks /Delete /TN 'qqbot-dsh-web' /F | Out-Null }
} else { Say '没有计划任务 qqbot-dsh-web（或已经删过）' }
foreach ($f in @((Join-Path $DataRoot 'start-dsh.cmd'), (Join-Path $DataRoot 'bin\dsh-web-run.mjs'))) {
  if (Test-Path $f) { RunIt "删文件：$f" { Remove-Item -Force $f } }
}

# ---------- 2) DSH home 里的 junction/软链（只删指向我们源码目录的）----------
$removed = 0
function IsOurs($path) {
  $item = Get-Item $path -Force -ErrorAction SilentlyContinue
  if (-not $item) { return $false }
  $target = $null
  try { $target = $item.Target } catch { }
  if (-not $target) { return $false }
  if ($target -is [array]) { $target = $target[0] }
  $t = [string]$target
  return ($t -like "$PluginsDir*") -or ($t -like "$BridgeDir*")
}
if (Test-Path $PluginLinks) {
  Get-ChildItem $PluginLinks -Force | Where-Object { $_.LinkType } | ForEach-Object {
    if (IsOurs $_.FullName) { RunIt "删软链：$($_.FullName)" { Remove-Item -Force $_.FullName }; $script:removed++ }
  }
}
$bridgeLink = Join-Path $ProfileDir 'node_modules\dsh-qq-onebot-bridge'
if (Test-Path $bridgeLink) {
  if (IsOurs $bridgeLink) { RunIt "删软链：$bridgeLink" { Remove-Item -Force $bridgeLink }; $removed++ }
  else { Warn "软链 $bridgeLink 指向别处，不动它" }
}
if ($removed -eq 0) { Say 'DSH home 里没有我们建的软链（或已经删过）' }

# ---------- 3) profile 配置里的挂载声明 ----------
if ($KeepProfileConfig) {
  Say '按参数保留 profile 配置（-KeepProfileConfig）'
} else {
  $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
  $pj = Join-Path $ProfileDir 'package.json'
  if (Test-Path $pj) {
    RunIt '从 profile/package.json 的 dsh.profile.bundles 里移除 dsh-qq-onebot-bridge' {
      Copy-Item $pj "$pj.bak-uninstall-$ts" -Force
      $data = Get-Content $pj -Raw | ConvertFrom-Json
      if ($data.dsh.profile.bundles) {
        $data.dsh.profile.bundles = @($data.dsh.profile.bundles | Where-Object { $_ -ne 'dsh-qq-onebot-bridge' })
      }
      $data | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $pj
    }
  }
  $cp = Join-Path $ProfileDir 'cordis.patch.yml'
  if (Test-Path $cp) {
    RunIt '从 profile/cordis.patch.yml 里移除桥接挂载块' {
      $lines = Get-Content $cp
      $start = -1
      for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*-\s*id:\s*dsh-qq-onebot-bridge\s*$') { $start = $i; break } }
      if ($start -ge 0) {
        Copy-Item $cp "$cp.bak-uninstall-$ts" -Force
        $indent = ($lines[$start] -replace '^(\s*).*$', '$1').Length
        $end = $lines.Count
        for ($j = $start + 1; $j -lt $lines.Count; $j++) {
          if ($lines[$j].Trim() -eq '') { continue }
          $cur = ($lines[$j] -replace '^(\s*).*$', '$1').Length
          if ($cur -le $indent -and $lines[$j].TrimStart().StartsWith('-')) { $end = $j; break }
        }
        $new = @($lines[0..($start - 1)]) + @($lines[$end..($lines.Count - 1)])
        Set-Content -Encoding UTF8 $cp $new
      } else { Say '  cordis.patch.yml 里没有桥接挂载块，不用改' }
    }
  }
}

# ---------- 4) 环境文件与用户环境变量 ----------
if (Test-Path $EnvFile) { RunIt "删环境文件：$EnvFile" { Remove-Item -Force $EnvFile } }
foreach ($name in @('QQ_DATA_ROOT', 'QQ_DSH_PORT', 'QQ_CONSOLE_PORT', 'QQ_ACCOUNT', 'QQ_WORKSPACE', 'DSH_HOME')) {
  if ([Environment]::GetEnvironmentVariable($name, 'User')) {
    RunIt "清用户环境变量 $name" { [Environment]::SetEnvironmentVariable($name, $null, 'User') }
  }
}

# ---------- 5) 源码 ----------
if ($KeepSources) {
  Say "按参数保留源码（-KeepSources）：$(Join-Path $DataRoot 'src')"
} else {
  foreach ($d in @($BridgeDir, $PluginsDir)) {
    if (Test-Path $d) { RunIt "删源码：$d" { Remove-Item -Recurse -Force $d } }
  }
  $srcDir = Join-Path $DataRoot 'src'
  if ((Test-Path $srcDir) -and -not (Get-ChildItem $srcDir -Force | Select-Object -First 1)) { RunIt "删空目录：$srcDir" { Remove-Item -Recurse -Force $srcDir } }
}

# ---------- 6) 数据 ----------
if ($Purge) {
  # 护栏：不删家目录/盘根；目标必须像我们的数据根
  $full = [System.IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
  if ($full -eq [System.IO.Path]::GetPathRoot($full).TrimEnd('\') -or $full -eq $env:USERPROFILE.TrimEnd('\')) {
    Warn "数据根看起来不对（$full），拒绝删除"; exit 1
  }
  $looksLike = $false
  foreach ($d in @('config', 'state', 'data', 'logs', 'subjects', 'media')) { if (Test-Path (Join-Path $full $d)) { $looksLike = $true } }
  if (-not $looksLike -and -not $Yes) { Warn "$full 里没有 config/state/data/logs/subjects —— 不像数据根，拒绝删除"; exit 1 }
  Say "删数据根（会话、控制台配置、QQ 登录态都会没）：$full"
  if (-not $Yes -and -not $DryRun) {
    $ans = Read-Host '        确认删除请输入数据根路径（原样）'
    if ($ans -ne $full) { Warn '输入不一致，已中止（什么都没删）'; exit 1 }
  }
  RunIt "删除 $full" { Remove-Item -Recurse -Force $full }
} else {
  Say "数据保留：$DataRoot（要一起删：-Purge -Yes）"
}

Write-Host ''
Say '本脚本没碰（按需自己处理）：'
Write-Host '    · dsh 本身：npm uninstall -g @deepseek-ai/dsh'
Write-Host '    · Node：winget uninstall OpenJS.NodeJS.LTS'
Write-Host '    · NapCat：官方安装器卸载'
Write-Host "    · DSH home（$DshHome）：里面还有别的 profile 与凭据，确认不用再删"
if ($DryRun) { Say '（以上都是干跑，实际什么都没做）' }
