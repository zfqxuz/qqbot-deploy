#!/usr/bin/env bash
# install-host.sh —— 不用 Docker 的安装（Linux / macOS）
#
# 为什么有它：有人机器上没 Docker，或者不想为了机器人装 Docker。
# 组成和容器版一样，只是把容器换成本机进程：
#   Node（npm 装 dsh）→ 桥接+插件（源码软链进 DSH home）→ NapCat（官方安装方式）
#   → systemd --user（Linux）/ launchd（macOS）管自启 → 控制台 /setup 收尾
#
# 用法：
#   bash install-host.sh                    一键（检测到就沿用，缺什么补什么）
#   bash install-host.sh --check            只体检，什么都不改
#   bash install-host.sh --dry-run          打印将要执行的每一步，不执行
#   bash install-host.sh --qq 2267595782 --port 3081 --console-port 8798
#   bash install-host.sh --data-root ~/qqbot --no-autostart
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

QQ_ARG=''; PORT=3081; CPORT=8798; ROOT="$HOME/qqbot"; DSH_VER=''; WS_ARG=''
DRY=0; CHECK=0; AUTO=1; SKIP_DSH=0; SRC_OVERRIDE=''; SRC_ARCHIVE=''
while [ $# -gt 0 ]; do
  case "$1" in
    --qq) QQ_ARG=${2:-}; shift 2 ;;
    --port) PORT=${2:-3081}; shift 2 ;;
    --console-port) CPORT=${2:-8798}; shift 2 ;;
    --data-root) ROOT=${2:-}; shift 2 ;;
    --workspace) WS_ARG=${2:-}; shift 2 ;;
    --dsh-version) DSH_VER=${2:-}; shift 2 ;;
    --no-autostart) AUTO=0; shift ;;
    --skip-dsh) SKIP_DSH=1; shift ;;
    --src-dir) SRC_OVERRIDE=${2:-}; shift 2 ;;
    --src-archive) SRC_ARCHIVE=${2:-}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（试试 --help）"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || die_root=1
[ -n "$ROOT" ] || { echo "数据根不能为空"; exit 2; }
WORKSPACE=${WS_ARG:-$ROOT/workspace}

log()  { echo "[host] $*"; }
warn() { echo "[host] ⚠ $*"; }
die()  { echo "[host] ✗ $*" >&2; exit 1; }
run()  { local desc=$1; shift; if [ "$DRY" = 1 ]; then echo "  · $desc"; echo "      $*"; return 0; fi; log "$desc"; "$@"; }

OS=$(uname -s)
case "$OS" in
  Linux) PLATFORM=linux ;;
  Darwin) PLATFORM=macos ;;
  *) die "这个脚本只支持 Linux / macOS；Windows 用同目录的 install-host.ps1" ;;
esac
ARCH=$(uname -m)
case "$ARCH" in x86_64|amd64) NODE_ARCH=x64 ;; arm64|aarch64) NODE_ARCH=arm64 ;; *) die "不支持的架构：$ARCH" ;; esac

DSH_HOME=${DSH_HOME:-$HOME/.dsh}
ENV_FILE="$HOME/.config/dsh-bot/dsh.env"
SRC_DIR="$ROOT/src"
BRIDGE_DIR="$SRC_DIR/dsh-qq-onebot-bridge"
PLUGINS_DIR="$SRC_DIR/dsh-plugins"
PROFILE="$DSH_HOME/profiles/web"
BRIDGE_REPO=${QQ_BRIDGE_REPO:-https://github.com/zfqxuz/dsh-qq-onebot-bridge.git}
PLUGINS_REPO=${QQ_PLUGINS_REPO:-https://github.com/zfqxuz/dsh-plugins.git}

have() { command -v "$1" >/dev/null 2>&1 && echo "✓" || echo "✗"; }

echo
echo "============================================================"
echo " 不用 Docker 的安装 · 体检（$PLATFORM/$NODE_ARCH）"
echo "============================================================"
NODE_V=$(node -v 2>/dev/null || echo '无')
NODE_OK=0
case "$NODE_V" in v2[0-9].*|v[3-9][0-9].*) NODE_OK=1 ;; esac
printf '  %-16s %s\n' "node" "$NODE_V $([ "$NODE_OK" = 1 ] && echo '（≥20，够用）' || echo '（缺或太旧 → 会装一份到 ~/.local）')"
printf '  %-16s %s\n' "npm / git / curl" "$(have npm) / $(have git) / $(have curl)"
printf '  %-16s %s\n' "已装 dsh" "$(command -v dsh >/dev/null 2>&1 && dsh --version 2>/dev/null | head -1 || echo 没有)"
printf '  %-16s %s\n' "DSH home" "$DSH_HOME"
printf '  %-16s %s\n' "数据根 / 工作区" "$ROOT / $WORKSPACE"
printf '  %-16s %s\n' "源码" "桥接 $([ -d "$BRIDGE_DIR/.git" ] && echo 已有 || echo 要拉) · 插件 $([ -d "$PLUGINS_DIR/.git" ] && echo 已有 || echo 要拉)"
if ss -ltn 2>/dev/null | grep -qE "[:.]$PORT "; then
  printf '  %-16s %s\n' "端口 $PORT" "被占用（$(ss -ltnp 2>/dev/null | grep -E "[:.]$PORT " | head -1 | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')）→ 想并存就 --port $((PORT+1))"
else
  printf '  %-16s %s\n' "端口 $PORT" "空 ✓"
fi
NAP_UP=$(ss -ltn 2>/dev/null | grep -cE ':(6099|6700) ')
printf '  %-16s %s\n' "协议端" "$([ "$NAP_UP" -gt 0 ] && echo "有端口在听（6099/6700）→ 可以直接复用" || echo '没检测到 → 第 7 步会给 NapCat 官方安装命令')"
if [ "$PLATFORM" = linux ]; then
  printf '  %-16s %s\n' "自启" "$(systemctl --user show-environment >/dev/null 2>&1 && echo 'systemd --user 可用 ✓' || echo '没有 systemd --user（跳过自启）')"
  printf '  %-16s %s\n' "免登录驻留" "$(loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q 'Linger=yes' && echo '已开 ✓' || echo "没开，要 sudo loginctl enable-linger $(id -un)")"
else
  printf '  %-16s %s\n' "自启" "launchd（~/Library/LaunchAgents）"
fi
echo "============================================================"
[ "$CHECK" = 1 ] && { echo; log "只体检（--check）：什么都没改"; exit 0; }
[ "$DRY" = 1 ] && { echo; log "干跑（--dry-run）：下面只打印步骤"; }

# ---------- 1. Node ----------
if [ "$NODE_OK" = 0 ]; then
  if [ "$PLATFORM" = macos ]; then
    if command -v brew >/dev/null 2>&1; then run "用 Homebrew 装 Node" brew install node
    else
      warn "macOS 上没 node 也没 brew。二选一："
      echo "    1) 装 Homebrew： /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
      echo "    2) 自己装 Node ≥20（nodejs.org），然后重跑本脚本"
    fi
  else
    NV=${NODE_TARBALL_VER:-v22.14.0}
    TB="node-$NV-linux-$NODE_ARCH.tar.xz"
    run "下载解压 Node $NV 到 ~/.local（不需要 sudo）" bash -c "
      set -e
      mkdir -p '$HOME/.local/lib' '$HOME/.local/bin'
      cd '$HOME/.local/lib'
      curl -fL -o '$TB' 'https://nodejs.org/dist/$NV/$TB'
      tar -xf '$TB'; rm -f '$TB'
      ln -sfn '$PWD/node-$NV-linux-$NODE_ARCH/bin/node' '$HOME/.local/bin/node'
      ln -sfn '$PWD/node-$NV-linux-$NODE_ARCH/bin/npm'  '$HOME/.local/bin/npm'
      ln -sfn '$PWD/node-$NV-linux-$NODE_ARCH/bin/npx'  '$HOME/.local/bin/npx'"
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi

# ---------- 2. dsh ----------
command -v npm >/dev/null 2>&1 || [ "$DRY" = 1 ] || die "没有 npm：先装好 Node ≥20 再重跑"
if [ "$SKIP_DSH" = 1 ]; then
  command -v dsh >/dev/null 2>&1 || die "--skip-dsh 但找不到 dsh"
  log "按参数跳过 npm 安装，用现有的 dsh：$(dsh --version 2>/dev/null | head -1)"
else
  run "安装/升级 dsh" npm install -g --no-fund --no-audit "@deepseek-ai/dsh${DSH_VER:+@$DSH_VER}"
fi
if [ "$DRY" = 0 ]; then
  command -v dsh >/dev/null 2>&1 || die "装完找不到 dsh（npm 全局 bin 不在 PATH？npm bin -g 看看）"
  log "dsh 版本：$(dsh --version 2>/dev/null | head -1)"
fi

# ---------- 3. 源码 ----------
export GIT_TERMINAL_PROMPT=0    # 仓库私有/没权限时立刻失败，而不是卡在输入用户名
if [ -n "$SRC_ARCHIVE" ] && [ -f "$SRC_ARCHIVE" ]; then
  run "解压随包源码 $SRC_ARCHIVE" bash -c "mkdir -p '$SRC_DIR' && tar -xzf '$SRC_ARCHIVE' -C '$SRC_DIR'"
fi
if [ -f "$BRIDGE_DIR/package.json" ]; then
  [ -d "$BRIDGE_DIR/.git" ] && run "更新桥接源码" git -C "$BRIDGE_DIR" pull --ff-only
  log "桥接源码已就绪：$BRIDGE_DIR"
else
  run "拉取桥接源码" git clone --depth 1 "$BRIDGE_REPO" "$BRIDGE_DIR" || {
    warn "拉不到桥接源码（$BRIDGE_REPO）。这个仓库可能是私有的，三种办法："
    echo "    1) 让仓库所有者把你加进协作者，或先 gh auth login / 配好 git 凭据"
    echo "    2) 用随部署包附带的源码包： --src-archive <包里的 src.tar.gz>"
    echo "    3) 本地已有源码： --src-dir <包含 dsh-qq-onebot-bridge 的目录>"
    die "没有桥接源码，装不下去"
  }
fi
if [ -d "$PLUGINS_DIR" ] && [ "$(ls -A "$PLUGINS_DIR" 2>/dev/null | head -1)" != "" ]; then
  [ -d "$PLUGINS_DIR/.git" ] && run "更新插件源码" git -C "$PLUGINS_DIR" pull --ff-only
  log "插件源码已就绪：$PLUGINS_DIR"
else
  run "拉取插件源码" git clone --depth 1 "$PLUGINS_REPO" "$PLUGINS_DIR" || warn "插件仓库拉不到，跳过（桥接能跑，插件功能会缺）"
fi

# ---------- 4. 接线（照抄容器 entrypoint：只动软链）----------
if [ "$DRY" = 1 ]; then
  echo "  · 把 $PLUGINS_DIR/* 软链进 $DSH_HOME/plugins/（保留已有配置）"
  echo "  · 把桥接软链进 $PROFILE/node_modules/dsh-qq-onebot-bridge"
  echo "  · 跑首启播种：node $BRIDGE_DIR/control/bin/qq-seed.mjs"
else
  mkdir -p "$DSH_HOME/plugins" "$ROOT/state" "$PROFILE/node_modules"
  for src in "$PLUGINS_DIR"/*/; do
    [ -d "$src" ] || continue
    name=$(basename "$src"); [ "$name" = node_modules ] && continue
    ln -sfn "${src%/}" "$DSH_HOME/plugins/$name"; log "  插件链接 $name → ${src%/}"
  done
  ln -sfn "$BRIDGE_DIR" "$PROFILE/node_modules/dsh-qq-onebot-bridge"; log "  桥接链接 → $BRIDGE_DIR"
  [ -f "$BRIDGE_DIR/control/bin/qq-seed.mjs" ] && run "首启播种（只补缺、不覆盖）" node "$BRIDGE_DIR/control/bin/qq-seed.mjs"
fi

# ---------- 5. 环境文件 ----------
PROXY_URL=${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}
if [ "$DRY" = 1 ]; then
  echo "  · 写 $ENV_FILE（PATH/代理 + QQ_DATA_ROOT/QQ_DSH_PORT/QQ_ACCOUNT/QQ_WORKSPACE/QQ_DSH_HOME）"
else
  mkdir -p "$(dirname "$ENV_FILE")"
  {
    echo "# 由 install-host.sh 生成于 $(date '+%F %T')；改完重启服务生效"
    echo "PATH=$HOME/.local/bin:$(dirname "$(command -v node)"):/usr/bin:/bin"
    echo "LANG=C.UTF-8"
    echo "HOME=$HOME"
    echo "DSH_HOME=$DSH_HOME"
    echo "QQ_DATA_ROOT=$ROOT"
    echo "QQ_DSH_PORT=$PORT"
    echo "QQ_CONSOLE_PORT=$CPORT"
    echo "QQ_ACCOUNT=${QQ_ARG:-}"
    echo "QQ_WORKSPACE=$WORKSPACE"
    echo "QQ_BRIDGE_DIR=$BRIDGE_DIR"
    echo "QQ_PLUGINS_DIR=$DSH_HOME/plugins"
    [ -n "$PROXY_URL" ] && { echo "HTTP_PROXY=$PROXY_URL"; echo "HTTPS_PROXY=$PROXY_URL"; echo "http_proxy=$PROXY_URL"; echo "https_proxy=$PROXY_URL"; }
    echo "NO_PROXY=127.0.0.1,localhost,::1"
  } > "$ENV_FILE"
  log "写了 $ENV_FILE"
fi

# ---------- 6. 自启 ----------
NODE_BIN=$(command -v node || echo /usr/bin/node)
if [ "$AUTO" = 1 ] && [ "$PLATFORM" = linux ]; then
  if [ "$DRY" = 1 ]; then echo "  · 写 ~/.config/systemd/user/{dsh-web,qq-acl-console}.service 并 enable --now"
  elif systemctl --user show-environment >/dev/null 2>&1; then
    UD="$HOME/.config/systemd/user"; mkdir -p "$UD"
    cat > "$UD/dsh-web.service" <<UNIT
[Unit]
Description=DSH web + QQ bridge (host mode, port $PORT)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$WORKSPACE
EnvironmentFile=-$ENV_FILE
Environment=DSH_HOME=$DSH_HOME
ExecStart=$NODE_BIN $(dirname "$(readlink -f "$(command -v dsh)")")/dsh web --no-open --port $PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
    cat > "$UD/qq-acl-console.service" <<UNIT
[Unit]
Description=QQ bot ACL console (127.0.0.1:$CPORT)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$BRIDGE_DIR
EnvironmentFile=-$ENV_FILE
ExecStart=$NODE_BIN $BRIDGE_DIR/control/bin/qq-acl-console.mjs --port $CPORT --data-root $ROOT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now dsh-web.service qq-acl-console.service
    log "systemd 用户服务已启用：dsh-web.service / qq-acl-console.service"
    loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q 'Linger=yes' \
      || warn "没开 linger：注销后服务会停。要开机就自动跑： sudo loginctl enable-linger $(id -un)"
  else
    warn "没有 systemd --user，跳过自启。手动起：dsh web --no-open --port $PORT"
  fi
elif [ "$AUTO" = 1 ] && [ "$PLATFORM" = macos ]; then
  AD="$HOME/Library/LaunchAgents"
  if [ "$DRY" = 1 ]; then echo "  · 写 $AD/com.qqbot.dsh-web.plist 并 launchctl load"
  else
    mkdir -p "$AD"
    DSH_BIN=$(command -v dsh || echo /usr/local/bin/dsh)
    cat > "$AD/com.qqbot.dsh-web.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.qqbot.dsh-web</string>
  <key>ProgramArguments</key><array>
    <string>$NODE_BIN</string><string>$DSH_BIN</string><string>web</string><string>--no-open</string><string>--port</string><string>$PORT</string>
  </array>
  <key>WorkingDirectory</key><string>$WORKSPACE</string>
  <key>EnvironmentVariables</key><dict>
    <key>QQ_DATA_ROOT</key><string>$ROOT</string>
    <key>DSH_HOME</key><string>$DSH_HOME</string>
    <key>PATH</key><string>$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLIST
    launchctl unload "$AD/com.qqbot.dsh-web.plist" 2>/dev/null || true
    launchctl load "$AD/com.qqbot.dsh-web.plist"
    log "launchd 已加载 com.qqbot.dsh-web（控制台照 HOST-INSTALL.md 再加一个 plist）"
  fi
fi

# ---------- 7. 协议端 ----------
echo
if [ "$NAP_UP" -gt 0 ]; then
  log "协议端已有端口在听（6099/6700）→ 复用 ✓"
else
  warn "没检测到协议端。NapCat 官方安装方式："
  if [ "$PLATFORM" = linux ]; then
    echo "    curl -o napcat.sh https://raw.githubusercontent.com/NapNeko/NapCat-Installer/main/script/install.sh"
    echo "    sudo bash napcat.sh"
  else
    echo "    https://github.com/NapNeko/NapCat-Mac-Installer/releases/latest"
  fi
  echo "    装完启动一次扫码登录；确认 6099（WebUI）与 6700（反连桥接）在听。详见 HOST-INSTALL.md 第 6 步。"
fi

# ---------- 8. 收尾 ----------
echo
echo "============================================================"
echo " 接下来：打开网页向导"
echo "============================================================"
echo "  控制台 /setup ： http://127.0.0.1:$CPORT/setup"
echo "  DSH 宿主      ： http://127.0.0.1:$PORT/   （token 在服务日志里：journalctl --user -u dsh-web -n 20）"
echo
echo "  三条验证命令（都要过）："
echo "    systemctl --user is-active dsh-web.service      # macOS: launchctl list | grep qqbot"
echo "    ss -ltn | grep ':6700 '                          # 桥接在听"
echo "    curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$CPORT/login   # 控制台 → 200"
echo
echo "  回退： systemctl --user disable --now dsh-web.service qq-acl-console.service"
echo "         rm -f $ENV_FILE $DSH_HOME/plugins/* $PROFILE/node_modules/dsh-qq-onebot-bridge"
echo "============================================================"
