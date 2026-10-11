#!/usr/bin/env bash
# install.sh —— 一条命令把 QQ 机器人跑起来
#   补全 .env → 建目录 → 拉/构建镜像 → 起栈 → 等就绪 → 告诉你接下来点哪里
#
# 用法：
#   bash install.sh                      Linux / WSL
#   bash install.sh --desktop            Windows/macOS 的 Docker Desktop（桥接网络 + 端口映射）
#   bash install.sh --qq 123456          非交互指定登录用的 QQ 号
#   bash install.sh --data-root /srv/qq  指定数据根（默认 ~/qqbot）
#   bash install.sh --dry-run            只检查 + 生成 .env，不起栈
#   bash install.sh --legacy-compat      从 systemd 老部署迁移过来时用（老配置里的绝对路径继续有效）
#
# 全新用户只需要改一项：登录用的 QQ 号（下面会问你）。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"

QQ_OPT=''; DATA_ROOT_OPT=''; DRY=0; DESKTOP=0; LEGACY_COMPAT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --qq) QQ_OPT=${2:-}; shift 2 ;;
    --data-root) DATA_ROOT_OPT=${2:-}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --desktop) DESKTOP=1; shift ;;
    --legacy-compat) LEGACY_COMPAT=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（试试 bash install.sh --help）"; exit 2 ;;
  esac
done

log()  { echo "[install] $*"; }
warn() { echo "[install] ⚠ $*"; }
die()  { echo "[install] ✗ $*" >&2; exit 1; }

cat <<'BANNER'
============================================================
 QQ 机器人 Docker 一键部署
   控制台 8798 · DSH 3081 · NapCat 6099 · 桥接 6700
============================================================
BANNER

# ---------- 0. 环境检查 ----------
command -v docker >/dev/null || die "没找到 docker。先装 Docker Engine 或 Docker Desktop，再回来跑这条命令。"
docker info >/dev/null 2>&1 || die "docker 命令在，但守护进程连不上（Docker Desktop 没启动？或当前用户不在 docker 组？）"
docker compose version >/dev/null 2>&1 || die "缺 docker compose 插件（需要 Docker Compose v2：docker compose version 能打印版本）"

# ---------- 1. 生成 / 补全 .env ----------
[ -f .env ] || { cp .env.example .env; log "已从 .env.example 生成 .env"; }

set_env() { # set_env KEY VALUE —— 只在"没填"时写入，绝不覆盖你已经填过的值
  local key=$1 value=$2
  [ -n "$value" ] || return 0
  # "已填"= 等号后面去掉空白和行内注释后还有内容
  [ -n "$(sed -n "s/^${key}=//p" .env 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]')" ] && return 0
  if grep -q "^${key}=" .env; then sed -i "s|^${key}=.*|${key}=${value}|" .env
  else printf '%s=%s\n' "$key" "$value" >> .env; fi
  log "填 $key=$value"
}

HOME_DIR=${HOME:-$(cd ~ && pwd)}
ROOT=${DATA_ROOT_OPT:-$HOME_DIR/qqbot}
DEF_REPOS=$(cd "$HERE/../../.." 2>/dev/null && pwd || echo '')

set_env QQ_UID "$(id -u)"
set_env QQ_GID "$(id -g)"
set_env QQ_DATA_ROOT "$ROOT"
set_env QQ_DSH_HOME "$HOME_DIR/.dsh"
set_env QQ_WORKSPACE "$ROOT/workspace"
set_env QQ_NAPCAT_DATA "$ROOT/napcat-data"
set_env QQ_NAPCAT_CONFIG "$ROOT/napcat-config"
set_env QQ_NAPCAT_CACHE "$ROOT/napcat-cache"
set_env QQ_DSH_PORT 3081
# 只有在源码仓库布局里（旁边就是两个源码仓库）才填这几个键；全新用户不需要它们
if [ -n "$DEF_REPOS" ] && [ -d "$DEF_REPOS/dsh-qq-onebot-bridge" ]; then
  set_env QQ_BRIDGE_REPO "$DEF_REPOS/dsh-qq-onebot-bridge"
  set_env QQ_PLUGINS_REPO "$DEF_REPOS/dsh-plugins"
  set_env QQ_REPOS_ROOT "$DEF_REPOS"
fi

# 登录用的 QQ 号：唯一必须由用户提供的值
CUR_QQ=$(sed -n 's/^QQ_ACCOUNT=//p' .env | head -1 | tr -d '[:space:]')
if [ -n "$QQ_OPT" ]; then
  case "$QQ_OPT" in *[!0-9]*) die "--qq 必须是纯数字（登录用的 QQ 号）" ;; esac
  if [ "$CUR_QQ" != "$QQ_OPT" ]; then sed -i "s|^QQ_ACCOUNT=.*|QQ_ACCOUNT=$QQ_OPT|" .env; log "填 QQ_ACCOUNT=$QQ_OPT"; fi
  CUR_QQ=$QQ_OPT
fi
if [ -z "$CUR_QQ" ]; then
  if [ -t 0 ]; then
    printf '[install] 请输入机器人登录用的 QQ 号（纯数字，之后也能在控制台改）：'
    read -r ans
    case "$ans" in
      ''|*[!0-9]*) die "没填或不是纯数字。也可以：bash install.sh --qq 123456" ;;
      *) sed -i "s|^QQ_ACCOUNT=.*|QQ_ACCOUNT=$ans|" .env; log "填 QQ_ACCOUNT=$ans"; CUR_QQ=$ans ;;
    esac
  else
    die "还没设置 QQ_ACCOUNT。用 bash install.sh --qq 你的QQ号，或先编辑 .env"
  fi
fi

# ---------- 2. 建目录 ----------
log "准备目录（数据/工作区/登录态）"
for d in "$(sed -n 's/^QQ_DATA_ROOT=//p' .env)" "$(sed -n 's/^QQ_DSH_HOME=//p' .env)" \
         "$(sed -n 's/^QQ_WORKSPACE=//p' .env)" "$(sed -n 's/^QQ_NAPCAT_DATA=//p' .env)" \
         "$(sed -n 's/^QQ_NAPCAT_CONFIG=//p' .env)" "$(sed -n 's/^QQ_NAPCAT_CACHE=//p' .env)"; do
  [ -n "$d" ] || continue
  mkdir -p "$d" 2>/dev/null || die "建不了目录：$d"
  [ -w "$d" ] || die "目录不可写：$d"
done
log "工作区：$(sed -n 's/^QQ_WORKSPACE=//p' .env)（首启为空；你在里面写的东西不会被镜像/容器重建影响）"

# ---------- 3. compose 文件组合 ----------
COMPOSE=(docker compose -f docker-compose.yml)
[ "$DESKTOP" = 1 ] && COMPOSE+=(-f docker-compose.desktop.yml)
[ "$LEGACY_COMPAT" = 1 ] && COMPOSE+=(-f docker-compose.legacy-compat.yml)
[ -f docker-compose.dev.yml ] && [ "${QQ_DEV_MOUNT:-0}" = 1 ] && COMPOSE+=(-f docker-compose.dev.yml)
"${COMPOSE[@]}" config >/dev/null || die "compose 配置校验失败（.env 里少了必填项？看上面的报错）"

if [ "$DRY" = 1 ]; then
  log "干跑结束（.env 已就绪，未起栈）。去掉 --dry-run 再跑一次即可启动。"
  exit 0
fi

# ---------- 4. 镜像：本地有就用，没有就拉，拉不到再看源码构建 ----------
TAG=$(sed -n 's/^QQ_TAG=//p' .env); TAG=${TAG:-v0.7.0}
HIMG=$(sed -n 's/^QQ_HARNESS_IMAGE=//p' .env); HIMG=${HIMG:-qqbot-harness:$TAG}
CIMG=$(sed -n 's/^QQ_CONSOLE_IMAGE=//p' .env); CIMG=${CIMG:-qqbot-console:$TAG}
if docker image inspect "$HIMG" >/dev/null 2>&1 && docker image inspect "$CIMG" >/dev/null 2>&1; then
  log "镜像已在本地：$HIMG / $CIMG"
else
  log "拉取镜像（$HIMG / $CIMG）"
  if ! "${COMPOSE[@]}" pull harness console; then
    if [ -z "$(sed -n 's/^QQ_HARNESS_IMAGE=//p' .env)" ] && [ -x ./build.sh ]; then
      warn "拉取失败，尝试本地构建（需要源码仓库）"
      ./build.sh || die "本地构建也失败了，看上面的输出"
    else
      die "拉取失败：检查网络，或确认 .env 里的 QQ_HARNESS_IMAGE/QQ_CONSOLE_IMAGE 可访问"
    fi
  fi
fi

# ---------- 5. 起栈 ----------
log "启动容器"
"${COMPOSE[@]}" up -d || die "启动失败，看上面的输出"

log "等待就绪（最多 120 秒）"
ok=0
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$(sed -n 's/^QQ_CONSOLE_PORT=//p' .env | head -1 || echo 8798)/login" 2>/dev/null || echo 000)
  if [ "$code" = 200 ] && { ss -ltn 2>/dev/null | grep -q ':6700 ' || [ "$DESKTOP" = 1 ]; }; then ok=1; break; fi
  sleep 2
done

CONSOLE_PORT=$(sed -n 's/^QQ_CONSOLE_PORT=//p' .env); CONSOLE_PORT=${CONSOLE_PORT:-8798}
DSH_PORT=$(sed -n 's/^QQ_DSH_PORT=//p' .env); DSH_PORT=${DSH_PORT:-3081}
echo
if [ "$ok" = 1 ]; then
  log "起好了 ✓"
else
  warn "等超时了，容器可能还在起（首次拉镜像会慢）。先看看：${COMPOSE[*]} ps 与 logs"
fi
"${COMPOSE[@]}" ps

cat <<TIP

============================================================
 接下来 4 步（脚本代替不了）
============================================================
 1. 打开 http://127.0.0.1:$CONSOLE_PORT/login ，设置控制台管理员密码
 2. 控制台左侧「机器人身份」页：
      私聊白名单 = 你自己的 QQ 号
      群白名单    = 要让机器人服务的群号（不需要就留空）
    保存。（白名单空着 = 谁都不回，这是安全默认）
 3. 让配置生效：      ${COMPOSE[*]} restart harness
 4. 回控制台「状态台」→ 扫码登录 QQ（首次要手机确认）

 常用命令
   看状态        ${COMPOSE[*]} ps
   看宿主日志    ${COMPOSE[*]} logs -f harness
   看 QQ 协议端  ${COMPOSE[*]} logs -f napcat
   重启宿主机    ${COMPOSE[*]} restart harness
   停机          ${COMPOSE[*]} down          （数据/工作区不受影响）
   备份 / 恢复   bash backup.sh   /   bash restore.sh <备份目录>
   升级          .env 里改 QQ_TAG → ${COMPOSE[*]} pull → ${COMPOSE[*]} up -d
                  （配置、会话、工作区都在宿主目录里，升级不动它们）
============================================================
TIP
