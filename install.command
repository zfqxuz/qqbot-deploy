#!/usr/bin/env bash
# macOS 双击入口：打开浏览器版安装向导（也可以命令行加参数，例如 ./install.command --custom）
cd "$(dirname "$0")" || exit 1
exec bash install.sh --desktop --wizard "$@"
