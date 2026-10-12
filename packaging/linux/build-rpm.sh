#!/usr/bin/env bash
# ============================================================
#  build-rpm.sh [版本号] [输出目录] —— 打一个 .rpm 安装包（与 .deb 同内容）
#
#  依赖 rpmbuild（Debian/Ubuntu：sudo apt install rpm；Fedora：自带）
#  本机没装 rpmbuild 也能跑构建流程的其它部分；CI 里由 ubuntu runner 装 rpm 后执行。
# ============================================================
set -euo pipefail
VER=${1:-0.0.0}
OUT=${2:-$(pwd)/dist}
HERE=$(cd "$(dirname "$0")" && pwd)
PKG_ROOT=$(cd "$HERE/../.." && pwd)
command -v rpmbuild >/dev/null || { echo "[rpm] 需要 rpmbuild（apt install rpm / dnf install rpm-build）"; exit 1; }

# RPM 的 Version 字段不允许 "-"（CI 实测报错：Illegal char '-' in: Version: 0.7.3-dev）。
# 用 "~" 替代：在 RPM 里 ~ 表示预发布，排序上小于正式版，语义正好对（0.7.3~dev < 0.7.3）。
SAFEVER=${VER//-/~}
echo "[rpm] 版本：$VER → RPM 版本 $SAFEVER"

TOP=$(mktemp -d)
trap 'rm -rf "$TOP"' EXIT
mkdir -p "$TOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS} "$OUT"
APPDIR="$TOP/qqbot-deploy-$SAFEVER"
mkdir -p "$APPDIR/opt/qqbot-deploy" "$APPDIR/usr/bin"

echo "[rpm] 1/3 拷贝部署包"
tar -C "$PKG_ROOT" \
    --exclude='.env' --exclude='.env.*' --exclude='dsh.env' \
    --exclude='backups' --exclude='build-context' --exclude='node_modules' \
    --exclude='__pycache__' --exclude='*.bak-*' --exclude='Dockerfile.*' \
    --exclude='.github' --exclude='packaging' --exclude='docker-compose.legacy-compat.yml' \
    -cf - . | tar -C "$APPDIR/opt/qqbot-deploy" -xf -

echo "[rpm] 2/3 生成命令入口"
for c in install:install-host.sh update:update-host.sh uninstall:uninstall-host.sh; do
  name=${c%%:*}; script=${c##*:}
  cat > "$APPDIR/usr/bin/qqbot-$name" <<SH
#!/bin/sh
exec bash /opt/qqbot-deploy/host/$script "\$@"
SH
  chmod 0755 "$APPDIR/usr/bin/qqbot-$name"
done

echo "[rpm] 3/3 rpmbuild"
tar -C "$TOP" -czf "$TOP/SOURCES/qqbot-deploy-$SAFEVER.tar.gz" "qqbot-deploy-$SAFEVER"
cat > "$TOP/SPECS/qqbot-deploy.spec" <<SPEC
Name:           qqbot-deploy
Version:        $SAFEVER
Release:        1%{?dist}
Summary:        QQ bot deploy kit for DeepSeek Harness (installer only)
License:        MIT
URL:            https://github.com/zfqxuz/qqbot-deploy
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch
Requires:       bash

%description
只放文件，不起服务、不碰数据。装完自己跑 qqbot-install（分层：已有 Node/dsh 不动）。
完整说明见 /opt/qqbot-deploy/UPDATE-UNINSTALL.md。

%prep
%setup -q

%install
mkdir -p %{buildroot}
cp -a opt %{buildroot}/opt
mkdir -p %{buildroot}/usr/bin
cp -a usr/bin/. %{buildroot}/usr/bin/
chmod 0755 %{buildroot}/usr/bin/qqbot-* || true

%files
/opt/qqbot-deploy
/usr/bin/qqbot-install
/usr/bin/qqbot-update
/usr/bin/qqbot-uninstall

%post
cat <<'MSG'

  qqbot-deploy 已装好（只放了文件，没有起任何服务）。
    开始安装： qqbot-install --check   →   qqbot-install
    以后更新： qqbot-update
    完整卸载： qqbot-uninstall（默认保留数据；--purge 才删）

MSG

%changelog
* $(date '+%a %b %d %Y') zfqxuz <zfqxuz@users.noreply.github.com> - $SAFEVER-1
- installer-only package
SPEC

rpmbuild --define "_topdir $TOP" -bb "$TOP/SPECS/qqbot-deploy.spec" >/dev/null
find "$TOP/RPMS" -name '*.rpm' -exec cp {} "$OUT/" \;
ls -la "$OUT"/*.rpm | sed 's/^/[rpm] 完成：/'
