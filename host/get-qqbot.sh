#!/usr/bin/env bash
# ============================================================
#  get-qqbot.sh —— 一行安装（Linux / macOS，不需要 Docker）
#
#  它会：把部署包拉到一个固定目录 → 交给包里的 host/install-host.sh 干正事。
#  install-host.sh 自己会分层判断（已有 Node / dsh 就不动），所以本脚本只负责"取包"。
#
#  用法（三选一）：
#    curl -fsSL https://raw.githubusercontent.com/zfqxuz/qqbot-deploy/main/host/get-qqbot.sh | bash -s -- --qq 123456789
#    curl -fsSL ... -o get-qqbot.sh && bash get-qqbot.sh --check      # 只体检
#    bash host/get-qqbot.sh --dry-run                                 # 已经在部署包里，直接跑
#
#  参数原样透传给 host/install-host.sh（--qq / --port / --data-root / --check / --dry-run /
#  --upgrade-dsh / --dsh-version / --skip-dsh / --no-autostart 都认）。
#  环境变量：QQBOT_REPO(默认 zfqxuz/qqbot-deploy) / QQBOT_REF(默认 main)
#            QQBOT_SRC(默认 ~/qqbot/src/qqbot-deploy) / QQBOT_REFRESH=1(强制重新下载)
# ============================================================
set -uo pipefail

REPO_SLUG=${QQBOT_REPO:-zfqxuz/qqbot-deploy}
REF=${QQBOT_REF:-main}
DEST=${QQBOT_SRC:-$HOME/qqbot/src/qqbot-deploy}

log() { echo "[get-qqbot] $*"; }
die() { echo "[get-qqbot] ✗ $*" >&2; exit 1; }

# ---------- 1) 已经在部署包里就直接用 ----------
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo '')
if [ -n "$HERE" ] && [ -f "$HERE/install-host.sh" ]; then
  log "用当前目录里的安装器：$HERE/install-host.sh"
  exec bash "$HERE/install-host.sh" "$@"
fi

# ---------- 2) 取包 ----------
if [ "${QQBOT_REFRESH:-0}" != 1 ] && [ -f "$DEST/host/install-host.sh" ]; then
  log "复用已经拉好的部署包：$DEST（要更新：QQBOT_REFRESH=1 重跑）"
else
  mkdir -p "$(dirname "$DEST")" || die "建不了目录 $(dirname "$DEST")"
  tmp=$(mktemp -d) || die "建不了临时目录"
  trap 'rm -rf "$tmp"' EXIT

  url="https://github.com/$REPO_SLUG/archive/refs/heads/$REF.tar.gz"
  log "下载部署包：$url"
  if command -v curl >/dev/null 2>&1 && curl -fL --connect-timeout 20 --max-time 300 -o "$tmp/pkg.tar.gz" "$url"; then
    tar -xzf "$tmp/pkg.tar.gz" -C "$tmp" || die "解压失败（包下坏了？）"
  elif command -v git >/dev/null 2>&1; then
    log "下载失败，改用 git clone"
    git clone --depth 1 --branch "$REF" "https://github.com/$REPO_SLUG.git" "$tmp/src" || die "git clone 也失败了"
  else
    die "既没有可用的 curl，也没有 git —— 装一个再重跑（Debian/Ubuntu：sudo apt install curl）"
  fi

  src=''
  for d in "$tmp"/*/; do
    [ -f "$d/host/install-host.sh" ] && { src=$d; break; }
  done
  [ -n "$src" ] || die "包结构和预期不一致：没找到 host/install-host.sh"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -a "$src." "$DEST/" || die "拷贝到 $DEST 失败"
  log "部署包就位：$DEST"
fi

[ -f "$DEST/host/install-host.sh" ] || die "$DEST 里没有 host/install-host.sh（包不完整）"

# ---------- 3) 交给真正的安装器 ----------
log "开始安装（参数：${*:-无}）"
exec bash "$DEST/host/install-host.sh" "$@"
