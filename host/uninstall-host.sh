#!/usr/bin/env bash
# ============================================================
#  uninstall-host.sh —— 宿主模式（不用 Docker）的卸载
#
#  默认卸载"我们装的东西"，**保留你的数据**：
#    停掉并删除自启服务（systemd / launchd）
#    删掉 DSH home 里我们建的软链（只删指向 $ROOT/src 的那种）
#    从 profile 配置里移除桥接的 bundle 声明（改前备份）
#    删掉安装时写的环境文件与 dsh 启动器
#    删掉 $ROOT/src 下的源码
#
#  不碰：Node、dsh（npm 全局）、NapCat、DSH home 本身、你的数据根（除非 --purge）
#
#  用法：
#    bash host/uninstall-host.sh --dry-run          先看它要删什么
#    bash host/uninstall-host.sh                    真卸（数据留着）
#    bash host/uninstall-host.sh --keep-sources     源码也留着
#    bash host/uninstall-host.sh --keep-profile-config  不动 profile 配置
#    bash host/uninstall-host.sh --purge -y         连数据根一起删（会话/登录态都没了）
#    bash host/uninstall-host.sh --no-services      不动 systemd/launchd（手工起服务、或在沙箱里跑）
#    bash host/uninstall-host.sh --data-root <目录> 显式指定数据根（脚本不信任环境变量）
#    bash host/uninstall-host.sh --dsh-home <目录>  显式指定 DSH home
# ============================================================
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); PKG=$(cd "$HERE/.." && pwd)
DRY=0; PURGE=0; YES=0; KEEP_SRC=0; KEEP_PROFILE=0; NO_SERVICES=0; ROOT_ARG=''; DSH_ARG=''
while [ $# -gt 0 ]; do
  case "$1" in
    --data-root) ROOT_ARG=${2:-}; shift 2 ;;   # 显式指定数据根（唯一可信来源之一）
    --dsh-home) DSH_ARG=${2:-}; shift 2 ;;     # 显式指定 DSH home
    --dry-run) DRY=1; shift ;;
    --purge) PURGE=1; shift ;;
    -y|--yes) YES=1; shift ;;
    --keep-sources) KEEP_SRC=1; shift ;;
    --keep-profile-config) KEEP_PROFILE=1; shift ;;
    --no-services) NO_SERVICES=1; shift ;;   # 不动 systemd/launchd（手工起服务、或在容器/沙箱里跑）
    -h|--help) awk 'NR>1 && /^set -/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done
log() { echo "[uninstall-host] $*"; }
warn() { echo "[uninstall-host] ⚠ $*"; }
run() { if [ "$DRY" = 1 ]; then echo "    $*"; else "$@"; fi; }

ENV_FILE="$HOME/.config/dsh-bot/dsh.env"
# ⚠️ 先把环境里的 QQ_* 卸掉：卸载是**破坏性**操作，"删哪个目录"绝不能受外部环境影响。
#    （2026-10-12 事故：在沙箱里测试本脚本时，环境里残留的 QQ_DATA_ROOT 指向真实数据根，
#      rm -rf 把真实数据删了。数据根现在只认 --data-root / 安装记录 / 默认值。）
for _k in $(sed -n 's/^\(QQ_[A-Z0-9_]*\)=.*/\1/p' "$ENV_FILE" 2>/dev/null); do unset "$_k"; done
unset _k QQ_DATA_ROOT QQ_WORKSPACE QQ_NAPCAT_DATA QQ_NAPCAT_CONFIG QQ_NAPCAT_CACHE DSH_HOME 2>/dev/null || true
[ -f "$ENV_FILE" ] && . "$ENV_FILE" 2>/dev/null || true   # 安装记录里的值才是可信的
ROOT=${ROOT_ARG:-${QQ_DATA_ROOT:-$HOME/qqbot}}
DSH_HOME=${DSH_ARG:-${DSH_HOME:-$HOME/.dsh}}   # DSH_HOME 同样只认显式参数/安装记录
BRIDGE_DIR="$ROOT/src/dsh-qq-onebot-bridge"
PLUGINS_DIR="$ROOT/src/dsh-plugins"
PROFILE_DIR="$DSH_HOME/profiles/web"
PLUGIN_LINKS_DIR="$DSH_HOME/plugins"

log "要卸载的部署：数据根 $ROOT · DSH home $DSH_HOME"
[ "$DRY" = 1 ] && log "干跑模式：下面只打印，不执行"

# ---------- 1) 自启服务 ----------
if [ "$NO_SERVICES" = 1 ]; then
  log "按参数跳过自启服务（--no-services）：systemd/launchd/计划任务都没动"
elif command -v systemctl >/dev/null 2>&1; then
  for u in dsh-web.service qq-acl-console.service; do
    if systemctl --user list-unit-files 2>/dev/null | grep -q "^$u"; then
      log "停用 systemd 单元：$u"
      run systemctl --user disable --now "$u" || warn "停用 $u 失败（可能已经停了）"
      run rm -f "$HOME/.config/systemd/user/$u"
    fi
  done
  run systemctl --user daemon-reload || true
fi
if [ "$(uname -s)" = Darwin ]; then
  for p in com.qqbot.dsh-web com.qqbot.console com.qqbot.qq-acl-console; do
    f="$HOME/Library/LaunchAgents/$p.plist"
    if [ -f "$f" ]; then
      log "卸载 launchd：$p"
      run launchctl unload "$f" 2>/dev/null || true
      run rm -f "$f"
    fi
  done
fi
# Windows 计划任务（在 WSL/Git Bash 里跑这个脚本时给提示，不跨系统删）
if command -v schtasks.exe >/dev/null 2>&1; then
  log "Windows 计划任务请在 PowerShell 里删：schtasks /Delete /TN qqbot-dsh-web /F"
fi

# ---------- 2) DSH home 里的软链（只删指向我们源码目录的）----------
removed_links=0
if [ -d "$PLUGIN_LINKS_DIR" ]; then
  for link in "$PLUGIN_LINKS_DIR"/*; do
    [ -L "$link" ] || continue
    target=$(readlink "$link" 2>/dev/null || true)
    case "$target" in
      "$PLUGINS_DIR"/*) log "删软链：$link → $target"; run rm -f "$link"; removed_links=$((removed_links+1)) ;;
    esac
  done
fi
bridge_link="$PROFILE_DIR/node_modules/dsh-qq-onebot-bridge"
if [ -L "$bridge_link" ]; then
  target=$(readlink "$bridge_link" 2>/dev/null || true)
  case "$target" in
    "$BRIDGE_DIR"|"$BRIDGE_DIR"/*) log "删软链：$bridge_link → $target"; run rm -f "$bridge_link"; removed_links=$((removed_links+1)) ;;
    *) warn "软链 $bridge_link 指向别处（$target），不动它" ;;
  esac
fi
[ "$removed_links" = 0 ] && log "DSH home 里没有我们建的软链（或已经删过）"

# ---------- 3) profile 配置里的 bundle 声明 ----------
if [ "$KEEP_PROFILE" = 1 ]; then
  log "按参数保留 profile 配置（--keep-profile-config）"
elif [ "$DRY" = 1 ]; then
  log "将从 profile 配置里移除 dsh-qq-onebot-bridge 的挂载声明（干跑不执行）"
else
  ts=$(date +%Y%m%d-%H%M%S)
  py=$(command -v python3 || true)
  if [ -n "$py" ]; then
    "$py" - "$PROFILE_DIR" "$ts" <<'PY' || warn "profile 配置清理失败（自己看一眼 $PROFILE_DIR）"
import json, pathlib, re, sys, shutil
prof = pathlib.Path(sys.argv[1]); ts = sys.argv[2]
# package.json：从 dsh.profile.bundles 里摘掉我们这一项
pj = prof / 'package.json'
if pj.exists():
    try:
        data = json.loads(pj.read_text())
        bundles = (data.get('dsh', {}).get('profile', {}) or {}).get('bundles')
        if isinstance(bundles, list) and 'dsh-qq-onebot-bridge' in bundles:
            shutil.copy2(pj, pj.with_name(pj.name + f'.bak-uninstall-{ts}'))
            data['dsh']['profile']['bundles'] = [b for b in bundles if b != 'dsh-qq-onebot-bridge']
            pj.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
            print('  profile/package.json：已移除 bundles 里的 dsh-qq-onebot-bridge（已备份）')
    except Exception as e:
        print(f'  profile/package.json 没动：{e}')
# cordis.patch.yml：删掉 - id: dsh-qq-onebot-bridge 那一整块（到下一个同级 - 或文件尾）
cp = prof / 'cordis.patch.yml'
if cp.exists():
    lines = cp.read_text().split('\n')
    start = next((i for i, l in enumerate(lines) if re.match(r'^\s*-\s*id:\s*dsh-qq-onebot-bridge\s*$', l)), None)
    if start is not None:
        indent = len(lines[start]) - len(lines[start].lstrip())
        end = len(lines)
        for j in range(start + 1, len(lines)):
            l = lines[j]
            if not l.strip():
                continue
            cur = len(l) - len(l.lstrip())
            if cur <= indent and l.lstrip().startswith('-'):
                end = j
                break
        shutil.copy2(cp, cp.with_name(cp.name + f'.bak-uninstall-{ts}'))
        cp.write_text('\n'.join(lines[:start] + lines[end:]))
        print('  profile/cordis.patch.yml：已移除桥接挂载块（已备份）')
    else:
        print('  profile/cordis.patch.yml：没有桥接挂载块，不用改')
PY
  else
    warn "没有 python3，profile 配置留给你手工改：$PROFILE_DIR/{package.json,cordis.patch.yml}"
  fi
fi

# ---------- 4) 环境文件 / 启动器 ----------
[ -f "$ENV_FILE" ] && { log "删环境文件：$ENV_FILE"; run rm -f "$ENV_FILE"; }
[ -f "$ROOT/bin/dsh-web-run.mjs" ] && { log "删启动器：$ROOT/bin/dsh-web-run.mjs"; run rm -f "$ROOT/bin/dsh-web-run.mjs"; }
run rmdir "$ROOT/bin" 2>/dev/null || true

# ---------- 5) 源码 ----------
if [ "$KEEP_SRC" = 1 ]; then
  log "按参数保留源码（--keep-sources）：$ROOT/src"
else
  for d in "$BRIDGE_DIR" "$PLUGINS_DIR"; do
    [ -e "$d" ] && { log "删源码：$d"; run rm -rf "$d"; }
  done
  run rmdir "$ROOT/src" 2>/dev/null || true
fi

# ---------- 6) 数据 ----------
if [ "$PURGE" = 1 ]; then
  # 护栏：不删家目录/根目录；目标必须看起来像我们的数据根（有 config|state|data|logs|subjects 之一）
  case "$ROOT" in /|"$HOME"|/home|/root|/usr|/etc|'') warn "数据根看起来不对（$ROOT），拒绝删除"; exit 1 ;; esac
  looks_like=0
  for d in config state data logs subjects media; do [ -e "$ROOT/$d" ] && looks_like=1; done
  if [ "$looks_like" = 0 ] && [ "$YES" != 1 ]; then
    warn "$ROOT 里没有 config/state/data/logs/subjects 任何一个 —— 不像我们的数据根，拒绝删除"
    warn "确认要删就自己来：rm -rf $ROOT"
    exit 1
  fi
  log "删数据根（会话、控制台配置、QQ 登录态都会没）：$ROOT"
  [ -d "$ROOT" ] && du -sh "$ROOT" 2>/dev/null | sed 's/^/        /'
  if [ "$YES" != 1 ] && [ "$DRY" != 1 ]; then
    printf '        确认删除请输入数据根路径（原样）：'; read -r ans
    [ "$ans" = "$ROOT" ] || { warn "输入不一致，已中止（什么都没删）"; exit 1; }
  fi
  run rm -rf "$ROOT"
else
  log "数据保留：$ROOT（要一起删：--purge -y）"
fi

echo
log "本脚本没碰（按需自己处理）："
echo "    · dsh 本身：npm uninstall -g @deepseek-ai/dsh"
echo "    · Node：用 brew/apt/winget 卸，或删 ~/.local/lib/node-*"
echo "    · NapCat：官方安装器卸载（Linux ~/Napcat、Windows 一键包、macOS Mac-Installer）"
echo "    · DSH home（$DSH_HOME）：里面还有别的 profile 与凭据，确认不用再删"
echo "    · 部署包目录本身：rm -rf $PKG"
[ "$DRY" = 1 ] && log "（以上都是干跑，实际什么都没做）"
