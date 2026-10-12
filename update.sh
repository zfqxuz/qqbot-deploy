#!/usr/bin/env bash
# ============================================================
#  update.sh —— 容器版更新（不动数据）
#
#  用法：
#    bash update.sh                按 .env 里现有的 tag 重新拉镜像并原地重建
#    bash update.sh --tag v0.7.3   换到指定 tag（写回 .env，先备份）
#    bash update.sh --check        只查有没有新版本，什么都不改
#    bash update.sh --dry-run      只打印将要执行的命令
#
#  数据（数据根 / DSH home / 工作区）都在 .env 指向的宿主目录里，更新只换镜像，
#  不动它们；控制台里配的东西、QQ 登录态也都留着。
# ============================================================
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE" || exit 1

TAG=''; CHECK=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG=${2:-}; shift 2 ;;
    --check) CHECK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) awk 'NR>1 && /^set -/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "未知参数：$1（试试 --help）"; exit 2 ;;
  esac
done

log() { echo "[update] $*"; }
warn() { echo "[update] ⚠ $*"; }
die() { echo "[update] ✗ $*" >&2; exit 1; }
run() { if [ "$DRY" = 1 ]; then echo "    $*"; else "$@"; fi; }

# 进程环境里的 QQ_* 会盖过 .env（compose 插值：进程环境 > .env 文件）——先把它们卸掉
for _k in $(sed -n 's/^\(QQ_[A-Z0-9_]*\)=.*/\1/p' .env 2>/dev/null); do unset "$_k"; done
unset _k

env_get() { sed -n "s/^$1=//p" .env 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]'; }

# ---------- 组装 compose（跑着的栈用它的组合，否则按 .env 猜）----------
build_compose() {
  COMPOSE=(docker compose -f docker-compose.yml)
  [ "$(env_get QQ_ONEBOT_MODE)" = napcat ] && COMPOSE+=(--profile napcat)
  [ -f docker-compose.legacy-compat.yml ] && COMPOSE+=(-f docker-compose.legacy-compat.yml)
  [ -f docker-compose.dev.yml ] && [ "$(env_get QQ_DEV_MOUNT)" = 1 ] && COMPOSE+=(-f docker-compose.dev.yml)
  if docker inspect qqbot-harness >/dev/null 2>&1; then
    local cfg proj f
    cfg=$(docker inspect qqbot-harness --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null)
    proj=$(docker inspect qqbot-harness --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null)
    if [ -n "$cfg" ] && [ -n "$proj" ]; then
      COMPOSE=(docker compose)
      IFS=',' read -r -a _files <<< "$cfg"
      for f in "${_files[@]}"; do COMPOSE+=(-f "$f"); done
      cd "$proj" || die "进不去项目目录 $proj"
      log "沿用运行中的组合（目录 $proj）"
    fi
  fi
}

# ---------- 版本比较：本地 .env 的 tag vs 上游最新 ----------
latest_upstream() { # GitHub releases/latest → 退回 tags 第一个
  local repo=${QQBOT_REPO:-zfqxuz/qqbot-deploy} api out
  api=$(curl -fsSL --connect-timeout 8 --max-time 15 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) || api=''
  out=$(printf '%s' "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  api=$(curl -fsSL --connect-timeout 8 --max-time 15 "https://api.github.com/repos/$repo/tags" 2>/dev/null) || return 1
  printf '%s' "$api" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' | head -1
}

CUR_TAG=$(env_get QQ_TAG); CUR_TAG=${CUR_TAG:-v1}
HARNESS_IMG=$(env_get QQ_HARNESS_IMAGE); CONSOLE_IMG=$(env_get QQ_CONSOLE_IMAGE)
CUR_VER=$(docker inspect qqbot-harness --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' 2>/dev/null || true)

if [ "$CHECK" = 1 ]; then
  log "当前 .env tag：$CUR_TAG（镜像：${HARNESS_IMG:-qqbot-harness:$CUR_TAG}）"
  [ -n "$CUR_VER" ] && log "运行中容器声明的版本：$CUR_VER"
  if ! command -v curl >/dev/null 2>&1; then warn "没有 curl，查不了上游最新版本"; exit 0; fi
  NEW=$(latest_upstream 2>/dev/null || true)
  if [ -z "$NEW" ]; then
    warn "查不到上游最新 release/tag（离线，或仓库还没有 release）—— 也没关系："
    echo "        固定 tag 的镜像重新构建后，bash update.sh 直接重拉就是新版"
    exit 0
  fi
  log "上游最新：$NEW"
  if [ "$NEW" = "$CUR_TAG" ]; then
    log "已经是最新（tag 一致）。想强制重拉一次：bash update.sh"
  else
    log "有新版本：$CUR_TAG → $NEW"
    echo "        更新：bash update.sh --tag $NEW"
  fi
  exit 0
fi

# ---------- 真更新 ----------
[ -f .env ] || die "这里没有 .env（要在部署包目录里跑）"
if [ -n "$TAG" ]; then
  cp -a .env ".env.bak-update-$(date +%Y%m%d-%H%M%S)"
  if grep -q '^QQ_TAG=' .env; then sed -i "s|^QQ_TAG=.*|QQ_TAG=$TAG|" .env; else echo "QQ_TAG=$TAG" >> .env; fi
  # 镜像名如果写死了旧 tag，也要一起替换（QQ_HARNESS_IMAGE / QQ_CONSOLE_IMAGE）
  for k in QQ_HARNESS_IMAGE QQ_CONSOLE_IMAGE; do
    v=$(env_get "$k"); [ -n "$v" ] || continue
    sed -i "s|^$k=.*|$k=$(printf '%s' "$v" | sed "s|:$CUR_TAG\$|:$TAG|")|" .env
  done
  log "tag：$CUR_TAG → $TAG（.env 已备份）"
  CUR_TAG=$TAG
fi

build_compose
log "compose：${COMPOSE[*]}"

log "1/3 拉镜像（只拉 harness / console）"
run "${COMPOSE[@]}" pull harness console || warn "拉取失败（离线？本地已有镜像就继续）"

log "2/3 原地重建（不动数据）"
run "${COMPOSE[@]}" up -d --remove-orphans || die "重建失败，看上面的报错"

if [ "$DRY" = 1 ]; then log "干跑结束（什么都没改）"; exit 0; fi

log "3/3 等就绪（最多 90 秒）"
ok=0
for i in $(seq 1 30); do
  for p in "$(env_get QQ_CONSOLE_PORT)" 8798; do
    [ -n "$p" ] || continue
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$p/setup" 2>/dev/null || echo 000)
    [ "$code" = 200 ] && { ok=1; break 2; }
  done
  sleep 3
done
[ "$ok" = 1 ] && log "✅ 更新完成（控制台 200）" || warn "控制台还没就绪，看看日志：${COMPOSE[*]} logs -f harness"

# DSH 地址（token 每次重启都会变）
dsh_url=$(docker logs qqbot-harness 2>&1 | grep -oE 'http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+' | tail -1)
[ -n "$dsh_url" ] && log "DSH：$dsh_url"
log "QQ 桥接会自动重连（NapCat 掉线后 5 秒重试）；控制台：http://127.0.0.1:$(env_get QQ_CONSOLE_PORT 2>/dev/null || echo 8798)/setup"
log "回滚：.env 里把 QQ_TAG 改回旧值 → bash update.sh（或 install.sh --repair）"
