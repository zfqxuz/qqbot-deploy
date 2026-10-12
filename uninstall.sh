#!/usr/bin/env bash
# ============================================================
#  uninstall.sh —— 容器版卸载（默认**不删数据**）
#
#  用法：
#    bash uninstall.sh                 停容器、删容器与网络；数据/镜像/登录态全留着
#    bash uninstall.sh --rmi           连两个镜像一起删（省几个 G）
#    bash uninstall.sh --purge -y      连**数据根**一起删（会话/配置/登录态都没了，谨慎）
#    bash uninstall.sh --dry-run       只打印将要执行的命令，什么都不做
#
#  它**不会**碰：
#    · 部署包目录本身（这个仓库是你自己 clone 的，要删自己 rm -rf）
#    · DSH home（~/.dsh，宿主模式也在用；里面有 profile 与凭据）
#    · NapCat 的登录态目录、NapCat 容器/原生安装（下面会打印怎么卸）
# ============================================================
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE" || exit 1

PURGE=0; RMI=0; DRY=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --rmi) RMI=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) awk 'NR>1 && /^set -/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "未知参数：$1（试试 --help）"; exit 2 ;;
  esac
done

log() { echo "[uninstall] $*"; }
warn() { echo "[uninstall] ⚠ $*"; }
die() { echo "[uninstall] ✗ $*" >&2; exit 1; }
run() { if [ "$DRY" = 1 ]; then echo "    $*"; else "$@"; fi; }

for _k in $(sed -n 's/^\(QQ_[A-Z0-9_]*\)=.*/\1/p' .env 2>/dev/null); do unset "$_k"; done
unset _k
env_get() { sed -n "s/^$1=//p" .env 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]'; }

DATA_ROOT=$(env_get QQ_DATA_ROOT)
[ -f .env ] || warn "这里没有 .env：compose 可能组不出来，但 --purge 仍然会按你确认的路径删"

# ---------- 组装 compose（跑着的栈用它的组合）----------
COMPOSE=(docker compose -f docker-compose.yml)
[ "$(env_get QQ_ONEBOT_MODE)" = napcat ] && COMPOSE+=(--profile napcat)
[ -f docker-compose.legacy-compat.yml ] && COMPOSE+=(-f docker-compose.legacy-compat.yml)
[ -f docker-compose.dev.yml ] && [ "$(env_get QQ_DEV_MOUNT)" = 1 ] && COMPOSE+=(-f docker-compose.dev.yml)
if docker inspect qqbot-harness >/dev/null 2>&1; then
  cfg=$(docker inspect qqbot-harness --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null)
  proj=$(docker inspect qqbot-harness --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null)
  if [ -n "$cfg" ] && [ -n "$proj" ]; then
    COMPOSE=(docker compose)
    IFS=',' read -r -a _files <<< "$cfg"
    for f in "${_files[@]}"; do COMPOSE+=(-f "$f"); done
    cd "$proj" 2>/dev/null && log "沿用运行中的组合（目录 $proj）"
  fi
fi

log "1/3 停容器并删除容器/网络（数据卷是宿主目录，动不到）"
run "${COMPOSE[@]}" down || warn "compose down 有报错（可能本来就停着），继续"

if [ "$RMI" = 1 ]; then
  log "2/3 删镜像"
  H=$(env_get QQ_HARNESS_IMAGE); C=$(env_get QQ_CONSOLE_IMAGE)
  [ -n "$H" ] && run docker image rm -f "$H" || true
  [ -n "$C" ] && run docker image rm -f "$C" || true
else
  log "2/3 镜像保留（要删：bash uninstall.sh --rmi）"
fi

if [ "$PURGE" = 1 ]; then
  log "3/3 删数据根（会话、配置、QQ 登录态都会没）"
  case "$DATA_ROOT" in /|"$HOME"|/home|/root|/usr|/etc|'')
    warn "数据根看起来不对（$DATA_ROOT），拒绝删除"; exit 1 ;; esac
  if [ -z "$DATA_ROOT" ]; then
    warn "QQ_DATA_ROOT 没读到，跳过（手工删：rm -rf <你的数据根>）"
  else
    echo "        将删除：$DATA_ROOT"
    [ -d "$DATA_ROOT" ] && du -sh "$DATA_ROOT" 2>/dev/null | sed 's/^/        /'
    if [ "$YES" != 1 ] && [ "$DRY" != 1 ]; then
      printf '        确认删除请输入数据根路径（原样）：'; read -r ans
      [ "$ans" = "$DATA_ROOT" ] || die "输入不一致，已中止（什么都没删）"
    fi
    run rm -rf "$DATA_ROOT"
  fi
else
  log "3/3 数据保留：${DATA_ROOT:-（没读到 QQ_DATA_ROOT）}"
  echo "        要连数据一起删：bash uninstall.sh --purge -y"
fi

echo
log "顺带说明（本脚本不碰这些）："
echo "    · NapCat 容器（如果协议端也是容器）：docker rm -f napcat"
echo "    · NapCat 原生安装：Linux 用官方安装器的卸载说明；Windows/macOS 用官方安装器卸载"
echo "    · DSH home（~/.dsh）里有 profile 和凭据，宿主模式还可能在用 → 确认没用再 rm -rf"
echo "    · 部署包目录本身：cd .. && rm -rf $(basename "$HERE")"
log "想连技能一起清掉：docker image prune（悬空层）/ docker system prune（会问）"
