#!/usr/bin/env bash
# macOS 双击入口：Finder 里双击即可（首次可能要右键 → 打开）
# 也支持带参数：./install.command --custom
cd "$(dirname "$0")" || exit 1
exec bash install.sh --desktop "$@"
