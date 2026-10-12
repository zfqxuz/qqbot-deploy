#!/usr/bin/env bash
# ============================================================
#  QQ 机器人 · macOS 双击入口（Finder 里双击即可）
#
#  自己判断该走哪条路：
#    · 有可用 Docker（docker 命令在且守护进程能连上）→ 容器版网页向导（Docker Desktop 模式）
#    · 没有 Docker                                   → "不用 Docker 的安装"（原生进程 + launchd 自启）
#  想强制某一条：  ./install.command host    /    ./install.command docker
#  只体检不改动：  ./install.command host --check
# ============================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1

MODE=${1:-auto}
case "$MODE" in
  host|docker) shift ;;
  auto) shift || true ;;
  -h|--help)
    cat <<'USAGE'

  用法：./install.command [host|docker] [传给安装脚本的其它参数]
    ./install.command              自动判断（有 Docker 走容器版，没有就走本机安装）
    ./install.command host         强制"不用 Docker 的安装"（不需要 Docker Desktop）
    ./install.command host --check 只体检，什么都不改
    ./install.command docker       强制"容器版"（需要 Docker Desktop）
USAGE
    exit 0 ;;
  *) MODE=auto ;;   # 其它参数当成是传给安装脚本的，走自动判断
esac

have_docker() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

if [ "$MODE" = auto ]; then
  if have_docker; then MODE=docker; else MODE=host; fi
fi

echo
if [ "$MODE" = docker ]; then
  echo "[1/2] 检测到可用的 Docker，走容器版网页向导（Docker Desktop 模式）"
  echo "      想改用本机安装：./install.command host"
  echo
  exec bash install.sh --desktop --wizard "$@"
else
  echo "[1/2] 没有可用的 Docker（或你指定了 host），走不用 Docker 的安装"
  echo "      分层来装：已有 Node 就不装 Node、已有 dsh 就不装 dsh，缺什么补什么。"
  echo "      只想先看看会做什么：./install.command host --check"
  echo
  exec bash host/install-host.sh "$@"
fi
