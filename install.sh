#!/usr/bin/env bash
# install.sh —— QQ 机器人安装（一键 / 向导两档）
#
#   bash install.sh              一键：先体检机器，只问"机器人用哪个 QQ 号"，其余用默认
#   bash install.sh --custom     向导：每一步都问你（回车=用检测到的默认值）
#   bash install.sh --check      只体检：打印机器现状与建议，什么都不改
#   bash install.sh --yes        全默认、零提问（没有终端时自动走这个）
#
# 常用参数：
#   --qq 123456                 登录用的 QQ 号
#   --mode napcat|reuse|none    协议端：自带容器 / 复用已有的 / 先不接 QQ
#   --ports 3081,8798           宿主端口,控制台端口（默认自动挑空闲的）
#   --data-root /srv/qq         数据根（默认 ~/qqbot）
#   --workspace /path           工作区（默认 <数据根>/workspace，必须可写）
#   --proxy http://ip:port      上游代理（默认探测环境变量；--no-proxy 强制直连）
#   --tz Asia/Shanghai          时区
#   --dev / --no-dev            开发者模式（源码可写 + 容器内 docker 权限；默认关）
#   --desktop                   Windows/macOS 的 Docker Desktop（桥接网络 + 端口映射）
#   --legacy-compat             从 systemd 老部署迁移（老配置里的绝对路径继续有效）
#   --repair                    按当前正在跑的 compose 组合原地重建（不动数据）
#   --dry-run                   体检 + 生成 .env，不起栈
#   -h / --help                 显示这段
#
# 脚本负责"装完就能用"：docker 组、工作区可写、目录、镜像、起栈、等就绪，
# 最后打印网页向导地址（控制台 /setup）—— 密码、白名单、扫码在网页上点完即可。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"

# ---------- 参数 ----------
MODE_ARG=''; QQ_ARG=''; PORTS_ARG=''; ROOT_ARG=''; WS_ARG=''; PROXY_ARG=''
TZ_ARG=''; CUSTOM=0; YES=0; CHECK=0; DRY=0; DESKTOP=0; LEGACY=0; DEV=''; REPAIR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --custom) CUSTOM=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --check) CHECK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --qq) QQ_ARG=${2:-}; shift 2 ;;
    --mode) MODE_ARG=${2:-}; shift 2 ;;
    --ports) PORTS_ARG=${2:-}; shift 2 ;;
    --data-root) ROOT_ARG=${2:-}; shift 2 ;;
    --workspace) WS_ARG=${2:-}; shift 2 ;;
    --proxy) PROXY_ARG=${2:-}; shift 2 ;;
    --no-proxy) PROXY_ARG=off; shift ;;
    --tz) TZ_ARG=${2:-}; shift 2 ;;
    --dev) DEV=1; shift ;;
    --no-dev) DEV=0; shift ;;
    --desktop) DESKTOP=1; shift ;;
    --legacy-compat) LEGACY=1; shift ;;
    --repair) REPAIR=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（试试 bash install.sh --help）"; exit 2 ;;
  esac
done
[ -t 0 ] || YES=1    # 没有终端（CI / 双击 / 管道）→ 一句话都不问

log()  { echo "[install] $*"; }
warn() { echo "[install] ⚠ $*"; }
die()  { echo "[install] ✗ $*" >&2; exit 1; }

# 交互问答：提示走 stderr（不会污染"返回值"），非交互时直接给默认值
ask_text() { # ask_text "问题" 默认值
  local q=$1 def=$2 ans=''
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$def"; return 0; fi
  printf '[install] %s%s: ' "$q" "$([ -n "$def" ] && printf '（回车=%s）' "$def")" >&2
  read -r ans || ans=''
  [ -n "$ans" ] || ans=$def
  printf '%s' "$ans"
}
ask_yesno() { # ask_yesno "问题" y|n → y/n
  local q=$1 def=$2 ans=''
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$def"; return 0; fi
  printf '[install] %s [y/n]（回车=%s）: ' "$q" "$def" >&2
  read -r ans || ans=''
  [ -n "$ans" ] || ans=$def
  case "$ans" in y|Y|yes|YES) printf 'y' ;; *) printf 'n' ;; esac
}
ask_choice() { # ask_choice "标题" 默认序号 "选项1" "选项2" ...
  local title=$1 def=$2; shift 2
  local n=0 line ans=''
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$def"; return 0; fi
  echo >&2; echo "[install] $title" >&2
  for line in "$@"; do n=$((n+1)); printf '    %d) %s\n' "$n" "$line" >&2; done
  printf '[install] 选一个（回车=%s）: ' "$def" >&2
  read -r ans || ans=''
  [ -n "$ans" ] || ans=$def
  case "$ans" in
    *[!0-9]*) printf '%s' "$def" ;;
    *) if [ "$ans" -ge 1 ] && [ "$ans" -le "$n" ]; then printf '%s' "$ans"; else printf '%s' "$def"; fi ;;
  esac
}

cat <<'BANNER'
============================================================
 QQ 机器人安装
   控制台 8798 · DSH 3081 · NapCat 6099 · 桥接 6700
============================================================
BANNER

# ---------- 0. 环境检查 ----------
command -v docker >/dev/null || die "没找到 docker。先装 Docker Engine 或 Docker Desktop，再回来跑这条命令。"
docker info >/dev/null 2>&1 || die "docker 命令在，但守护进程连不上（Docker Desktop 没启动？或当前用户不在 docker 组？）"
docker compose version >/dev/null 2>&1 || die "缺 docker compose 插件（需要 Docker Compose v2：docker compose version 能打印版本）"

port_in_use() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"; }
port_owner() { # 占用端口的"人话"：优先读进程命令行（比 ss 给的线程名有用）
  local line pid cmd
  line=$(ss -ltnp 2>/dev/null | grep -E "[:.]$1 ")
  pid=$(printf '%s' "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" | cut -c1-36 | sed 's/ *$//')
    [ -n "$cmd" ] && { printf '%s' "$cmd"; return 0; }
  fi
  printf '%s' "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1
}
container_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
free_port_from() { local p=$1; while port_in_use "$p"; do p=$((p+1)); done; printf '%s' "$p"; }

# ---------- 1. 体检（只读） ----------
log "体检中（只读，什么都不改）…"
OS_KIND=$(uname -s)
ARCH=$(uname -m)
grep -qi microsoft /proc/version 2>/dev/null && OS_KIND="WSL2"
DOCKER_V=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')
COMPOSE_V=$(docker compose version --short 2>/dev/null || echo '?')
MEM_TOTAL=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || echo '?')
MEM_AVAIL=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || echo '?')
SPACE_FREE=$(df -h "${ROOT_ARG:-$HOME}" 2>/dev/null | awk 'NR==2{print $4}')

# 端口：默认 3081 DSH / 8798 控制台；被占就自动挑下一个空闲的
LABEL_DSH='空 ✓'; LABEL_CONSOLE='空 ✓'; LABEL_BRIDGE='空闲 ✓'; LABEL_NAPCAT='空闲（还没装协议端）'
port_in_use 3081 && LABEL_DSH="被占用（$(port_owner 3081)）"
port_in_use 8798 && LABEL_CONSOLE="被占用（$(port_owner 8798)）"
port_in_use 6700 && LABEL_BRIDGE="被占用（$(port_owner 6700)）"
port_in_use 6099 && LABEL_NAPCAT="被占用（$(container_running napcat && printf 'napcat 容器' || port_owner 6099)）"
PORT_DSH=$(free_port_from 3081)
PORT_CONSOLE=$(free_port_from 8798)
BRIDGE_BUSY=0; port_in_use 6700 && BRIDGE_BUSY=1

# QQ 号：分两类 —— "协议端正在用的" 和 "桌面 QQ 登录过的"（后者不能直接当机器人号）
QQ_FROM_PROTOCOL=$(ps -eo args= 2>/dev/null | grep -oE '(^| )-q [0-9]{5,12}( |$)' | awk '{print $2}' | sort -u | head -3 | tr '\n' ' ' | sed 's/ $//')
QQ_FROM_ENV=''; [ -f .env ] && QQ_FROM_ENV=$(sed -n 's/^QQ_ACCOUNT=//p' .env | head -1 | tr -d '[:space:]')
QQ_FROM_NAPCAT_CFG=''
for d in "$HOME/qqbot/napcat-config"; do
  [ -d "$d" ] || continue
  hit=$(ls "$d" 2>/dev/null | sed -n 's/^onebot11_\([0-9]\{5,12\}\)\.json$/\1/p' | head -1)
  [ -n "$hit" ] && QQ_FROM_NAPCAT_CFG=$hit
done
QQ_FROM_DESKTOP=''
for d in /mnt/c/Users/*/Documents/Tencent\ Files/*/ "$HOME/Documents/Tencent Files"/*/; do
  b=$(basename "$d" 2>/dev/null)
  case "$b" in ''|*[!0-9]*) continue ;; esac
  QQ_FROM_DESKTOP=${QQ_FROM_DESKTOP:-$b}
done

NAPCAT_CONTAINER=''; container_running napcat && NAPCAT_CONTAINER=$(docker inspect napcat --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' 2>/dev/null)
ONEBOT_ELSEWHERE=''
[ -z "$NAPCAT_CONTAINER" ] && port_in_use 6099 && ONEBOT_ELSEWHERE="6099 上有别的协议端 WebUI（$(port_owner 6099)）"
LEGACY_UNITS=$(systemctl --user list-units --all --no-legend 'dsh-web*' 'qq-acl-console*' 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')
GIT_V=$(command -v git >/dev/null 2>&1 && git --version | awk '{print $3}' || echo '')
GH_STATE=''
if command -v gh >/dev/null 2>&1; then
  _u=$(gh api user --jq .login 2>/dev/null || true)
  GH_STATE=${_u:+已登录 $_u}; [ -z "$GH_STATE" ] && GH_STATE='装了但没登录'
fi
PROXY_FOUND=${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}
PROXY_STATE=''
if [ -n "$PROXY_FOUND" ]; then
  _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 -x "$PROXY_FOUND" https://api.deepseek.com 2>/dev/null || echo 000)
  case "$_code" in ''|000|5??) PROXY_STATE='探活不通' ;; *) PROXY_STATE="探活可用（HTTP $_code）" ;; esac
fi

echo
echo "============================================================"
echo " 机器体检"
echo "============================================================"
printf '  %-14s %s\n' "系统" "$OS_KIND · $ARCH · Docker $DOCKER_V · Compose $COMPOSE_V"
printf '  %-14s %s\n' "资源" "内存 ${MEM_TOTAL}GB（可用 ${MEM_AVAIL}GB）· 目标盘可用 ${SPACE_FREE:-?}"
printf '  %-14s %s\n' "端口" "DSH 3081→$PORT_DSH（$LABEL_DSH）"
printf '  %-14s %s\n' "" "控制台 8798→$PORT_CONSOLE（$LABEL_CONSOLE）"
printf '  %-14s %s\n' "" "桥接 6700 $LABEL_BRIDGE · NapCat 6099 $LABEL_NAPCAT"
printf '  %-14s %s\n' "协议端在用的号" "${QQ_FROM_PROTOCOL:-没检测到}${QQ_FROM_NAPCAT_CFG:+（配置里记着 $QQ_FROM_NAPCAT_CFG）}"
printf '  %-14s %s\n' "桌面 QQ 登录过" "${QQ_FROM_DESKTOP:-没检测到}（只作提示：桌面 QQ 与机器人同号会互相踢下线）"
if [ -n "$NAPCAT_CONTAINER" ]; then
  printf '  %-14s %s\n' "已有协议端" "napcat 容器在跑（$NAPCAT_CONTAINER）→ 可以直接复用，不装新镜像"
elif [ -n "$ONEBOT_ELSEWHERE" ]; then
  printf '  %-14s %s\n' "已有协议端" "$ONEBOT_ELSEWHERE"
else
  printf '  %-14s %s\n' "已有协议端" "没有 → 要机器人就得装一个（NapCat 容器）"
fi
printf '  %-14s %s\n' "旧部署" "${LEGACY_UNITS:-没有}${LEGACY_UNITS:+ （systemd 老部署和容器二选一，别同时跑）}"
printf '  %-14s %s\n' "选装" "git ${GIT_V:-未装} · gh ${GH_STATE:-未装} · 代理 ${PROXY_FOUND:-没配}${PROXY_STATE:+（$PROXY_STATE）}"
echo "============================================================"

if [ "$CHECK" = 1 ]; then
  echo
  log "只体检（--check）：什么都没改。想装就 bash install.sh（一键）或 bash install.sh --custom（向导）。"
  exit 0
fi

# ---------- 2. 选择 ----------
DEF_MODE=napcat
[ -n "$NAPCAT_CONTAINER" ] || [ -n "$ONEBOT_ELSEWHERE" ] && DEF_MODE=reuse
MODE=''
if [ -n "$MODE_ARG" ]; then
  MODE=$MODE_ARG
elif [ "$CUSTOM" = 1 ]; then
  DEF_CHOICE=1; [ "$DEF_MODE" = reuse ] && DEF_CHOICE=2
  _c=$(ask_choice "第 1/6 步 · QQ 怎么接" "$DEF_CHOICE" \
    "自带协议端容器（默认；装 NapCat 镜像约 1.4GB，需要扫码登录）" \
    "复用本机已有的协议端（${NAPCAT_CONTAINER:+napcat 容器在跑}${ONEBOT_ELSEWHERE}；不装镜像）" \
    "先不接 QQ（只起 DSH + 控制台；不装镜像、不用填号）")
  case "$_c" in 1) MODE=napcat ;; 2) MODE=reuse ;; *) MODE=none ;; esac
else
  MODE=$DEF_MODE
fi
case "$MODE" in napcat|reuse|none) : ;; *) die "--mode 只能是 napcat / reuse / none" ;; esac

QQ_ACCOUNT=''
if [ "$MODE" = napcat ]; then
  QQ_ACCOUNT=${QQ_ARG:-}
  _src=''
  [ -n "$QQ_ACCOUNT" ] && _src='（你指定的）'
  if [ -z "$QQ_ACCOUNT" ] && [ -n "$QQ_FROM_PROTOCOL" ]; then QQ_ACCOUNT=$QQ_FROM_PROTOCOL; _src="（检测到协议端正在用这个号）"; fi
  if [ -z "$QQ_ACCOUNT" ] && [ -n "$QQ_FROM_ENV" ]; then QQ_ACCOUNT=$QQ_FROM_ENV; _src='（沿用上次 .env 里的号）'; fi
  if [ -z "$QQ_ACCOUNT" ]; then
    QQ_ACCOUNT=$(ask_text "机器人登录用的 QQ 号（纯数字）" "")
    _src='（你输入的）'
  fi
  [ -n "$QQ_ACCOUNT" ] || die "没给 QQ 号：加 --qq 123456，或改用 --mode reuse / --mode none"
  log "机器人号：$QQ_ACCOUNT $_src"
  case "$QQ_ACCOUNT" in *[!0-9]*) die "QQ 号必须是纯数字：$QQ_ACCOUNT" ;; esac
  if [ -n "$QQ_FROM_DESKTOP" ] && [ "$QQ_ACCOUNT" = "$QQ_FROM_DESKTOP" ]; then
    warn "你选的 $QQ_ACCOUNT 正是这台机器桌面 QQ 登录过的号。"
    warn "NapCat 和桌面 QQ 在 QQ 眼里都是\"电脑端\"，同号同时在线会互相踢下线 —— 建议换个小号；坚持用也行。"
  fi
fi

if [ "$CUSTOM" = 1 ]; then
  if [ -n "$PORTS_ARG" ]; then
    PORT_DSH=${PORTS_ARG%%,*}; PORT_CONSOLE=${PORTS_ARG##*,}
  else
    _p=$(ask_text "第 2/6 步 · 宿主端口,控制台端口" "$PORT_DSH,$PORT_CONSOLE")
    PORT_DSH=${_p%%,*}; PORT_CONSOLE=${_p##*,}
  fi
  case "$PORT_DSH$PORT_CONSOLE" in *[!0-9]*) die "端口必须是数字：$PORT_DSH,$PORT_CONSOLE" ;; esac
  ROOT_ARG=$(ask_text "第 3/6 步 · 数据根（会话/配置/登录态）" "${ROOT_ARG:-$HOME/qqbot}")
  WS_ARG=$(ask_text "第 4/6 步 · 工作区（助手写代码的地方，必须可写）" "${WS_ARG:-$ROOT_ARG/workspace}")
  if [ -z "$DEV" ]; then
    _d=$(ask_yesno "第 5/6 步 · 开发者模式？（源码可写 + 容器里能用 docker；代价是容器≈宿主 root）" n)
    [ "$_d" = y ] && DEV=1 || DEV=0
  fi
  if [ -z "$PROXY_ARG" ]; then
    _x=$(ask_text "第 6/6 步 · 上游代理（回车=检测值${PROXY_FOUND:+ $PROXY_FOUND}；填 off=强制直连）" "${PROXY_FOUND}")
    case "$_x" in off|OFF|none|NONE) PROXY_ARG=off ;; '') : ;; *) PROXY_ARG=$_x ;; esac
  fi
  [ -n "$TZ_ARG" ] || TZ_ARG=$(ask_text "时区" "Asia/Shanghai")
fi
# 显式 --ports 在任何模式下都生效（一键 / 静默也认）
if [ -n "$PORTS_ARG" ]; then
  case "$PORTS_ARG" in
    *,*) PORT_DSH=${PORTS_ARG%%,*}; PORT_CONSOLE=${PORTS_ARG##*,}
         case "$PORT_DSH$PORT_CONSOLE" in *[!0-9]*) die "端口必须是数字：$PORTS_ARG" ;; esac ;;
    *) die "--ports 要写成 宿主端口,控制台端口，例如 --ports 3081,8798" ;;
  esac
fi

# ---------- 3. 生成 / 补全 .env ----------
[ -f .env ] || { cp .env.example .env; log "已从 .env.example 生成 .env"; }

set_env() { # 只在"没填"时写入，绝不覆盖你已经填过的值
  local key=$1 value=$2
  [ -n "$value" ] || return 0
  [ -n "$(sed -n "s/^${key}=//p" .env 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]')" ] && return 0
  if grep -q "^${key}=" .env; then sed -i "s|^${key}=.*|${key}=${value}|" .env
  else printf '%s=%s\n' "$key" "$value" >> .env; fi
  log "填 $key=$value"
}
refresh_env() { # 机器/用户显式给的值：以新的为准（会覆盖旧值）
  local key=$1 value=$2 cur
  [ -n "$value" ] || return 0
  cur=$(sed -n "s/^${key}=//p" .env 2>/dev/null | head -1 | tr -d '[:space:]')
  [ "$cur" = "$value" ] && return 0
  if grep -q "^${key}=" .env; then sed -i "s|^${key}=.*|${key}=${value}|" .env
  else printf '%s=%s\n' "$key" "$value" >> .env; fi
  log "填 $key=$value（原值：${cur:-空}）"
}
clear_env() { # 显式清空（例如 --no-proxy）
  local key=$1
  grep -q "^${key}=" .env || return 0
  sed -i "s|^${key}=.*|${key}=|" .env
  log "清空 $key"
}
env_get() { sed -n "s/^$1=//p" .env 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]'; }

HOME_DIR=${HOME:-$(cd ~ && pwd)}
ROOT=${ROOT_ARG:-$HOME_DIR/qqbot}
set_env QQ_UID "$(id -u)"
set_env QQ_GID "$(id -g)"
set_env QQ_DATA_ROOT "$ROOT"
set_env QQ_DSH_HOME "$HOME_DIR/.dsh"
[ -n "$WS_ARG" ] && set_env QQ_WORKSPACE "$WS_ARG"
set_env QQ_WORKSPACE "$ROOT/workspace"
set_env QQ_NAPCAT_DATA "$ROOT/napcat-data"
set_env QQ_NAPCAT_CONFIG "$ROOT/napcat-config"
set_env QQ_NAPCAT_CACHE "$ROOT/napcat-cache"
[ -n "$TZ_ARG" ] && set_env TZ "$TZ_ARG"
set_env TZ Asia/Shanghai
[ -n "$QQ_ACCOUNT" ] && refresh_env QQ_ACCOUNT "$QQ_ACCOUNT"
refresh_env QQ_ONEBOT_MODE "$MODE"
refresh_env QQ_DSH_PORT "$PORT_DSH"
refresh_env QQ_CONSOLE_PORT "$PORT_CONSOLE"
case "$PROXY_ARG" in
  '')  : ;;
  off) clear_env UPSTREAM_PROXY ;;
  *)   refresh_env UPSTREAM_PROXY "$PROXY_ARG" ;;
esac
[ "$DEV" = 1 ] && set_env QQ_DEV_MOUNT 1

DOCKER_SOCK=/var/run/docker.sock
if [ -S "$DOCKER_SOCK" ]; then
  refresh_env QQ_DOCKER_GID "$(stat -c %g "$DOCKER_SOCK" 2>/dev/null || echo '')"
else
  warn "没找到 $DOCKER_SOCK —— 容器内 docker 功能会不可用（不影响 QQ 本体）"
fi

WS_CUR=$(env_get QQ_WORKSPACE)
WS_ROOT_DEF=$(dirname "$WS_CUR")
set_env QQ_WORKSPACE_ROOT "${QQ_WORKSPACE_ROOT:-$WS_ROOT_DEF}"
WS_ROOT_CUR=$(env_get QQ_WORKSPACE_ROOT)
case "$WS_CUR/" in
  "$WS_ROOT_CUR"/*) : ;;
  *) warn "工作区 $WS_CUR 不在工作区根 $WS_ROOT_CUR 之下 → 工作区根改为 $(dirname "$WS_CUR")"
     refresh_env QQ_WORKSPACE_ROOT "$(dirname "$WS_CUR")" ;;
esac

DEF_REPOS=$(cd "$HERE/../../.." 2>/dev/null && pwd || echo '')
if [ -n "$DEF_REPOS" ] && [ -d "$DEF_REPOS/dsh-qq-onebot-bridge" ]; then
  set_env QQ_BRIDGE_REPO "$DEF_REPOS/dsh-qq-onebot-bridge"
  set_env QQ_PLUGINS_REPO "$DEF_REPOS/dsh-plugins"
  set_env QQ_REPOS_ROOT "$DEF_REPOS"
fi

# ---------- 4. 建目录 + 校验可写 ----------
log "准备目录（数据/工作区/登录态/DSH home）"
for key in QQ_DATA_ROOT QQ_DSH_HOME QQ_WORKSPACE QQ_WORKSPACE_ROOT QQ_NAPCAT_DATA QQ_NAPCAT_CONFIG QQ_NAPCAT_CACHE; do
  d=$(env_get "$key")
  [ -n "$d" ] || continue
  case "$key" in QQ_NAPCAT_*) strict=0 ;; *) strict=1 ;; esac
  if [ ! -d "$d" ]; then
    if ! mkdir -p "$d" 2>/dev/null; then
      if [ "$strict" = 1 ]; then die "建不了目录（$key=$d）。先手工建好： mkdir -p \"$d\""; fi
      warn "$key=$d 建不了（NapCat 容器启动时会自己建；确认父目录存在即可）"
      continue
    fi
  fi
  probe="$d/.install-write-probe.$$"
  if ! ( : > "$probe" ) 2>/dev/null; then
    rm -f "$probe" 2>/dev/null || true
    if [ "$strict" = 1 ]; then
      die "目录不可写（$key=$d）。容器以你的 uid 跑，必须可写。
    被容器以 root 建过就改属主： sudo chown -R $(id -u):$(id -g) \"$d\"
    或换路径： --workspace /path   （数据根用 --data-root /path）"
    fi
    warn "$key=$d 宿主不可写（NapCat 容器内部是 root，能写；仅提示）"
  fi
  rm -f "$probe" 2>/dev/null || true
done
log "工作区：$(env_get QQ_WORKSPACE)（实测可写 ✓）"
log "工作区根：$(env_get QQ_WORKSPACE_ROOT)（控制台里可绑定的范围）"

# ---------- 5. compose 组合 ----------
COMPOSE=(docker compose -f docker-compose.yml)
[ "$MODE" = napcat ] && COMPOSE+=(--profile napcat)
[ "$DESKTOP" = 1 ] && COMPOSE+=(-f docker-compose.desktop.yml)
[ "$LEGACY" = 1 ] && COMPOSE+=(-f docker-compose.legacy-compat.yml)
{ [ -f docker-compose.dev.yml ] && [ "$(env_get QQ_DEV_MOUNT)" = 1 ]; } && COMPOSE+=(-f docker-compose.dev.yml)

if [ "$REPAIR" = 1 ] && docker inspect qqbot-harness >/dev/null 2>&1; then
  CFG=$(docker inspect qqbot-harness --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}')
  PROJ=$(docker inspect qqbot-harness --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}')
  if [ -n "$CFG" ] && [ -n "$PROJ" ]; then
    COMPOSE=(docker compose)
    IFS=',' read -r -a _files <<< "$CFG"
    for f in "${_files[@]}"; do COMPOSE+=(-f "$f"); done
    cd "$PROJ" || die "进不去项目目录 $PROJ"
    log "修复模式：沿用运行中的组合 ${CFG}（目录 $PROJ）"
  fi
fi
"${COMPOSE[@]}" config >/dev/null || die "compose 配置校验失败（.env 里少了必填项？看上面的报错）"
if [ "$BRIDGE_BUSY" = 1 ] && [ "$MODE" = napcat ]; then
  warn "6700 已被占用（$(port_owner 6700)）：桥接要在这个端口听 OneBot 反连。"
  warn "那是你已有的协议端就改用 --mode reuse；是别的服务就先把它挪开。"
fi

if [ "$DRY" = 1 ]; then
  echo
  log "干跑结束（.env 已就绪，未起栈）。去掉 --dry-run 再跑一次即可启动。"
  exit 0
fi

# ---------- 6. 镜像 ----------
TAG=$(env_get QQ_TAG); TAG=${TAG:-v0.7.2}
HIMG=$(env_get QQ_HARNESS_IMAGE); HIMG=${HIMG:-qqbot-harness:$TAG}
CIMG=$(env_get QQ_CONSOLE_IMAGE); CIMG=${CIMG:-qqbot-console:$TAG}
NEED_PULL=0
docker image inspect "$HIMG" >/dev/null 2>&1 && docker image inspect "$CIMG" >/dev/null 2>&1 || NEED_PULL=1
[ "$REPAIR" = 1 ] && { NEED_PULL=0; log "修复模式：不动镜像（要升级就改 QQ_TAG 后正常跑一次 install.sh）"; }
if [ "$NEED_PULL" = 1 ]; then
  log "拉取镜像（$HIMG / $CIMG）"
  if ! "${COMPOSE[@]}" pull harness console; then
    if [ -z "$(env_get QQ_HARNESS_IMAGE)" ] && [ -x ./build.sh ]; then
      warn "拉取失败，尝试本地构建（需要源码仓库）"
      ./build.sh || die "本地构建也失败了，看上面的输出"
    else
      die "拉取失败：检查网络，或确认 .env 里的 QQ_HARNESS_IMAGE/QQ_CONSOLE_IMAGE 可访问"
    fi
  fi
fi

# ---------- 7. 起栈 ----------
log "启动容器（$( [ "$MODE" = napcat ] && echo '含 QQ 协议端' || echo '不含 QQ 协议端' )）"
"${COMPOSE[@]}" up -d || die "启动失败，看上面的输出"

log "等待就绪（最多 120 秒）"
ok=0
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT_CONSOLE/login" 2>/dev/null || echo 000)
  if [ "$code" = 200 ]; then
    if [ "$MODE" != napcat ] || ss -ltn 2>/dev/null | grep -q ':6700 '; then ok=1; break; fi
  fi
  sleep 2
done
echo
[ "$ok" = 1 ] && log "起好了 ✓" || warn "等超时了，容器可能还在起（首次拉镜像会慢）。先看看：${COMPOSE[*]} ps 与 logs"
"${COMPOSE[@]}" ps

# ---------- 8. 自检 + 下一步 ----------
say_check() { printf '  %-22s %s\n' "$1" "$2"; }
echo
echo "============================================================"
echo " 环境自检"
echo "============================================================"
case "$MODE" in
  napcat) say_check "协议端" "自带 NapCat 容器" ;;
  reuse)  say_check "协议端" "复用已有的（这次没装也没启）" ;;
  none)   say_check "协议端" "不接 QQ（没装）" ;;
esac
say_check "工作区（可写）" "$(env_get QQ_WORKSPACE)"
say_check "工作区根（可绑定范围）" "$(env_get QQ_WORKSPACE_ROOT)"
say_check "数据根" "$(env_get QQ_DATA_ROOT)"
say_check "DSH home" "$(env_get QQ_DSH_HOME)"
say_check "控制台 / DSH 端口" "$(env_get QQ_CONSOLE_PORT) / $(env_get QQ_DSH_PORT)"
say_check "镜像 tag" "$TAG"
docker inspect qqbot-harness >/dev/null 2>&1 && say_check "容器内 docker" "$(docker exec qqbot-console docker version --format '{{.Server.Version}}' 2>/dev/null || echo '不可用（不影响 QQ）')"

CONSOLE_PORT=$(env_get QQ_CONSOLE_PORT)
cat <<TIP

============================================================
 接下来：打开网页向导，一步一步点就行
============================================================
  http://127.0.0.1:$CONSOLE_PORT/setup

 它会带你做完四件事（每件都可以先跳过，之后随时补）：
    1. 设控制台管理员密码
    2. 填白名单（你自己的 QQ；群白名单不需要就留空）
    3. 选装：GitHub token / git 身份 / 工作区
    4. 扫码登录 QQ$([ "$MODE" = napcat ] && echo '（用自带的 NapCat）' || echo '（你选了复用/不接，按你的情况来）')

 打不开就用控制台首页，左侧逐页配置：http://127.0.0.1:$CONSOLE_PORT/

 常用命令
   看状态        ${COMPOSE[*]} ps
   看宿主日志    ${COMPOSE[*]} logs -f harness
   看协议端日志  ${COMPOSE[*]} logs -f napcat
   改完配置重载  bash install.sh --repair     （按当前运行组合原地重建，不动数据）
   停机          ${COMPOSE[*]} down           （数据/工作区不受影响）
   备份 / 恢复   bash backup.sh   /   bash restore.sh <备份目录>
   升级          .env 改 QQ_TAG → ${COMPOSE[*]} pull → ${COMPOSE[*]} up -d
   看机器体检    bash install.sh --check
   重新向导      bash install.sh --custom

 说明：密码、token、白名单、工作区都在控制台网页里配，不要靠改 .env 或挂宿主路径。
============================================================
TIP
