#!/usr/bin/env bash
# ============================================================
#  build-deb.sh [版本号] [输出目录] —— 打一个 .deb 安装包
#
#  它装的是"安装器"本身，不是机器人本体：
#    /opt/qqbot-deploy/…        部署包（compose + 脚本 + 文档）
#    /usr/bin/qqbot-install     跑宿主安装（分层：已有 Node/dsh 不动）
#    /usr/bin/qqbot-update      更新
#    /usr/bin/qqbot-uninstall   卸载（默认保留数据）
#  装完不会自动起服务、不会动你的数据 —— 你自己跑 qqbot-install（这符合"包管理器只放文件"的惯例）。
#
#  依赖：dpkg-deb（Debian/Ubuntu 自带）。用法：
#    bash packaging/linux/build-deb.sh 0.7.3 /tmp/out
# ============================================================
set -euo pipefail
VER=${1:-0.0.0}
OUT=${2:-$(pwd)/dist}
HERE=$(cd "$(dirname "$0")" && pwd)
PKG_ROOT=$(cd "$HERE/../.." && pwd)          # deploy/qqbot
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

command -v dpkg-deb >/dev/null || { echo "[deb] 需要 dpkg-deb（Debian/Ubuntu 自带）"; exit 1; }
mkdir -p "$OUT"

APP=/opt/qqbot-deploy
mkdir -p "$STAGE$APP" "$STAGE/usr/bin" "$STAGE/DEBIAN"

echo "[deb] 1/4 拷贝部署包 → $APP"
# 只带用户需要的东西：脚本、compose、文档、一行安装入口；不带 .env / 备份 / 构建上下文
tar -C "$PKG_ROOT" \
    --exclude='.env' --exclude='.env.*' --exclude='dsh.env' \
    --exclude='backups' --exclude='build-context' --exclude='node_modules' \
    --exclude='__pycache__' --exclude='*.bak-*' --exclude='Dockerfile.*' \
    --exclude='.github' --exclude='packaging' --exclude='docker-compose.legacy-compat.yml' \
    -cf - . | tar -C "$STAGE$APP" -xf -
chmod -R a+rX "$STAGE$APP"

echo "[deb] 2/4 生成命令入口（qqbot-install / update / uninstall）"
cat > "$STAGE/usr/bin/qqbot-install" <<'SH'
#!/bin/sh
# 宿主安装（不用 Docker）：分层判断，已有 Node/dsh 不重装
exec bash /opt/qqbot-deploy/host/install-host.sh "$@"
SH
cat > "$STAGE/usr/bin/qqbot-update" <<'SH'
#!/bin/sh
exec bash /opt/qqbot-deploy/host/update-host.sh "$@"
SH
cat > "$STAGE/usr/bin/qqbot-uninstall" <<'SH'
#!/bin/sh
exec bash /opt/qqbot-deploy/host/uninstall-host.sh "$@"
SH
chmod 0755 "$STAGE/usr/bin/"qqbot-*

echo "[deb] 3/4 写 control"
SIZE=$(du -sk "$STAGE$APP" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<CTRL
Package: qqbot-deploy
Version: $VER
Section: net
Priority: optional
Architecture: all
Maintainer: zfqxuz <zfqxuz@users.noreply.github.com>
Homepage: https://github.com/zfqxuz/qqbot-deploy
Description: QQ bot deploy kit for DeepSeek Harness (installer only)
 Ships the deploy kit under $APP and three commands:
 qqbot-install / qqbot-update / qqbot-uninstall.
 It installs nothing by itself: no service is enabled and no data is touched.
 Run "qqbot-install" (it is tiered: an existing Node/dsh is left alone).
Installed-Size: $SIZE
CTRL

cat > "$STAGE/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
cat <<'MSG'

  qqbot-deploy 已装好（只放了文件，没有起任何服务）。

    开始安装：  qqbot-install --check     # 先体检，什么都不改
                qqbot-install             # 真装（分层：已有 Node/dsh 不动）
    以后更新：  qqbot-update
    卸载本包：  sudo dpkg -r qqbot-deploy  # 只删程序；数据在 ~/qqbot 与 ~/.dsh，另用
                                          # qqbot-uninstall（默认保留数据，--purge 才删）

  完整说明： /opt/qqbot-deploy/UPDATE-UNINSTALL.md
MSG
exit 0
POST
chmod 0755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'PRE'
#!/bin/sh
set -e
if [ -d /etc/systemd/user ] || [ -d "$HOME/.config/systemd/user" ]; then
  echo "  提示：如果装过 qqbot 的自启服务，先停掉："
  echo "        systemctl --user disable --now dsh-web.service qq-acl-console.service"
  echo "        （或直接跑 qqbot-uninstall 做完整卸载）"
fi
exit 0
PRE
chmod 0755 "$STAGE/DEBIAN/prerm"

echo "[deb] 4/4 打包"
OUTFILE="$OUT/qqbot-deploy_${VER}_all.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$OUTFILE" >/dev/null
echo "[deb] 完成：$OUTFILE"
dpkg-deb -f "$OUTFILE" Package Version Installed-Size 2>/dev/null | sed 's/^/       /'
