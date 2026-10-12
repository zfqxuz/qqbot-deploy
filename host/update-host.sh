#!/usr/bin/env bash
# ============================================================
#  update-host.sh —— 宿主模式（不用 Docker）的更新
#
#  更新三样东西，都是**就地**更新，不动数据：
#    ① 部署包本身（在包里跑就是 git pull；一行安装的会用 QQBOT_REFRESH 重拉）
#    ② 桥接与插件源码（$ROOT/src 下的 git 仓库，ff-only）
#    ③ 插件（如果 profile 里是从 npm 装的，就走 pnpm update）
#  然后重跑首启播种（只补缺）+ 重启自启服务。
#
#  用法：
#    bash host/update-host.sh            更新到最新并重启服务
#    bash host/update-host.sh --check    只查版本，什么都不改
#    bash host/update-host.sh --dry-run  只打印要执行的命令
#    bash host/update-host.sh --tag v0.7.3   切到部署包的某个 tag（git checkout）
# ============================================================
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); PKG=$(cd "$HERE/.." && pwd)
CHECK=0; DRY=0; TAG=''; NO_RESTART=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --tag) TAG=${2:-}; shift 2 ;;
    --no-restart) NO_RESTART=1; shift ;;   # 只更新文件，不碰服务（手工起服务时用）
    -h|--help) awk 'NR>1 && /^set -/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done
log() { echo "[update-host] $*"; }
warn() { echo "[update-host] $*" >&2; }
run() { if [ "$DRY" = 1 ]; then echo "    $*"; else "$@"; fi; }

# 数据根 / DSH home：优先环境变量，其次读安装时写的 dsh.env，最后按默认
ENV_FILE="$HOME/.config/dsh-bot/dsh.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
fi
ROOT=${QQ_DATA_ROOT:-$HOME/qqbot}
DSH_HOME=${DSH_HOME:-$HOME/.dsh}
BRIDGE_DIR="$ROOT/src/dsh-qq-onebot-bridge"
PLUGINS_DIR="$ROOT/src/dsh-plugins"
PROFILE_DIR="$DSH_HOME/profiles/web"

local_ver() { [ -f "$1/package.json" ] && sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$1/package.json" | head -1; }
npm_latest() { timeout 20 npm view --prefer-online "$1" version 2>/dev/null | tail -1; }
github_latest() {
  local repo=${QQBOT_REPO:-zfqxuz/qqbot-deploy} api
  api=$(curl -fsSL --connect-timeout 8 --max-time 15 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) || api=''
  [ -n "$api" ] && printf '%s' "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

# ---------- 版本总览 ----------
log "数据根：$ROOT"
log "桥接源码版本：$(local_ver "$BRIDGE_DIR" || echo '（没装/没读出来）')"
log "插件 npm 最新：$(npm_latest @zfqxuz/dsh-qq-onebot-bridge || echo '（查不到，离线？）')"
PKG_VER=$(local_ver "$PKG" 2>/dev/null || true)
[ -n "$PKG_VER" ] && log "部署包版本：$PKG_VER"
UP=$(github_latest 2>/dev/null || true)
[ -n "$UP" ] && log "部署包上游最新：$UP"

if [ "$CHECK" = 1 ]; then
  log "只检查（--check）：什么都没改。要更新：bash host/update-host.sh"
  exit 0
fi

# ---------- ① 部署包自己 ----------
if [ -d "$PKG/.git" ]; then
  if [ -n "$TAG" ]; then
    log "部署包切到 $TAG"
    run git -C "$PKG" fetch --tags --depth 1 origin || warn "fetch 失败（离线？）"
    run git -C "$PKG" checkout "$TAG" || warn "切到 $TAG 失败"
  else
    log "部署包：git pull --ff-only"
    run git -C "$PKG" pull --ff-only || warn "pull 失败（本地有改动？或者你在用的是解压包）"
  fi
else
  warn "当前不是 git 检出的部署包（解压/一行安装的）：要更新请重跑一行安装并加 QQBOT_REFRESH=1"
  echo "        curl -fsSL https://raw.githubusercontent.com/zfqxuz/qqbot-deploy/main/host/get-qqbot.sh | QQBOT_REFRESH=1 bash -s -- <原参数>"
fi

# ---------- ② 源码 ----------
for d in "$BRIDGE_DIR" "$PLUGINS_DIR"; do
  [ -d "$d/.git" ] || { warn "不是 git 仓库，跳过：$d"; continue; }
  log "更新源码：$d"
  run git -C "$d" pull --ff-only || warn "更新失败：$d（本地有改动？）"
done

# ---------- ③ 插件（npm 装的才走这条）----------
if [ -f "$PROFILE_DIR/package.json" ] && grep -q '@zfqxuz/dsh-qq-onebot-bridge' "$PROFILE_DIR/package.json"; then
  log "插件是 npm 装的：pnpm update"
  run dsh plugin --profile web update @zfqxuz/dsh-qq-onebot-bridge || warn "pnpm update 失败，可手工：cd $PROFILE_DIR && pnpm update @zfqxuz/dsh-qq-onebot-bridge"
else
  log "插件是本地目录软链装的：源码已更新（上面 ②），不用 npm 更新"
fi

# ---------- 重新播种 + 重启 ----------
if [ -f "$BRIDGE_DIR/control/bin/qq-seed.mjs" ]; then
  log "重新播种（只补缺、不覆盖你改过的配置）"
  run node "$BRIDGE_DIR/control/bin/qq-seed.mjs" || warn "播种失败"
fi

restarted=0
if [ "$NO_RESTART" = 1 ]; then
  log "按参数不重启服务（--no-restart）：改完自己重启 dsh 进程"
elif command -v systemctl >/dev/null 2>&1 && systemctl --user list-unit-files 2>/dev/null | grep -q '^dsh-web.service'; then
  log "重启 systemd 用户服务"
  run systemctl --user restart dsh-web.service qq-acl-console.service && restarted=1
elif command -v launchctl >/dev/null 2>&1 && [ -f "$HOME/Library/LaunchAgents/com.qqbot.dsh-web.plist" ]; then
  log "重启 launchd 服务"
  run launchctl kickstart -k "gui/$(id -u)/com.qqbot.dsh-web" && restarted=1
fi
[ "$restarted" = 1 ] || warn "没找到自启服务：如果你是手动起的，重启你自己的 dsh 进程即可"

if [ "$DRY" = 0 ]; then
  sleep 3
  for p in 3080 3081; do
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$p/" 2>/dev/null || echo 000)
    [ "$code" != 000 ] && log "DSH 在 $p 上有响应（HTTP $code）"
  done
  log "更新完成。桥接会话/数据都在 $ROOT，没被碰过"
fi
