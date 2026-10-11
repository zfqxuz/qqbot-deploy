#!/usr/bin/env bash
# restore.sh <备份目录> —— 恢复数据后起栈
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
SRC=${1:?用法: bash restore.sh <备份目录>}
[ -f "$SRC/qqbot-data.tar.gz" ] || { echo "缺 qqbot-data.tar.gz"; exit 1; }
DATA=$(sed -n 's/^QQ_DATA_ROOT=//p' .env); DSH=$(sed -n 's/^QQ_DSH_HOME=//p' .env)
echo "[restore] 停栈"; docker compose down || true
echo "[restore] 恢复数据到 $DATA / $DSH"
tar -xzf "$SRC/qqbot-data.tar.gz" -C "$(dirname "$DATA")"
[ -f "$SRC/dsh-home.tar.gz" ] && tar -xzf "$SRC/dsh-home.tar.gz" -C "$(dirname "$DSH")"
[ -f "$SRC/env.backup" ] && cp "$SRC/env.backup" .env && echo "[restore] 已恢复 .env"
echo "[restore] 起栈"; docker compose up -d
echo "[restore] 完成；若 QQ 掉登录态，打开 8798 状态台扫码"
