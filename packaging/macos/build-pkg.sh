#!/usr/bin/env bash
# ============================================================
#  build-pkg.sh [版本号] [输出目录] —— 打一个 macOS .pkg（与 .deb 同内容）
#
#  只能在 macOS 上跑（pkgbuild 是 macOS 自带工具）；CI 里用 macos-latest runner。
#  它装的是"安装器"本身：/usr/local/share/qqbot-deploy + /usr/local/bin/qqbot-{install,update,uninstall}
#  装完不会自动起服务、不碰数据。
# ============================================================
set -euo pipefail
VER=${1:-0.0.0}
OUT=${2:-$(pwd)/dist}
HERE=$(cd "$(dirname "$0")" && pwd)
PKG_ROOT=$(cd "$HERE/../.." && pwd)

command -v pkgbuild >/dev/null || { echo "[pkg] 需要 macOS 的 pkgbuild（只能在 mac 上打 .pkg）"; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT" "$STAGE/usr/local/share/qqbot-deploy" "$STAGE/usr/local/bin"

echo "[pkg] 1/3 拷贝部署包"
tar -C "$PKG_ROOT" \
    --exclude='.env' --exclude='.env.*' --exclude='dsh.env' \
    --exclude='backups' --exclude='build-context' --exclude='node_modules' \
    --exclude='__pycache__' --exclude='*.bak-*' --exclude='Dockerfile.*' \
    --exclude='.github' --exclude='packaging' --exclude='docker-compose.legacy-compat.yml' \
    -cf - . | tar -C "$STAGE/usr/local/share/qqbot-deploy" -xf -
chmod -R a+rX "$STAGE/usr/local/share/qqbot-deploy"

echo "[pkg] 2/3 生成命令入口"
for c in install:install-host.sh update:update-host.sh uninstall:uninstall-host.sh; do
  name=${c%%:*}; script=${c##*:}
  cat > "$STAGE/usr/local/bin/qqbot-$name" <<SH
#!/bin/sh
exec bash /usr/local/share/qqbot-deploy/host/$script "\$@"
SH
  chmod 0755 "$STAGE/usr/local/bin/qqbot-$name"
done

echo "[pkg] 3/3 pkgbuild"
pkgbuild --root "$STAGE" \
  --identifier com.zfqxuz.qqbot-deploy \
  --version "$VER" \
  --install-location / \
  "$OUT/qqbot-deploy-$VER.pkg"
ls -la "$OUT/qqbot-deploy-$VER.pkg" | sed 's/^/[pkg] 完成：/'
echo "[pkg] 提示：未签名/未公证 → 首次打开会被 Gatekeeper 拦（右键打开，或 xattr -d com.apple.quarantine）"
