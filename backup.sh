#!/usr/bin/env bash
# backup.sh [输出目录] —— 打包数据 + 配置 + secrets（默认脱敏：不含 sessions 与 napcat 登录态？可选）
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
OUT=${1:-$HERE/backups}; STAMP=$(date +%Y%m%d-%H%M%S); NAME="qqbot-backup-$STAMP"
DATA=$(sed -n 's/^QQ_DATA_ROOT=//p' .env); DSH=$(sed -n 's/^QQ_DSH_HOME=//p' .env)
[ -n "$DATA" ] && [ -n "$DSH" ] || { echo "先准备 .env"; exit 1; }
mkdir -p "$OUT/$NAME"
echo "[backup] 复制数据（含 NapCat 登录态，体积较大）"
tar -czf "$OUT/$NAME/qqbot-data.tar.gz" -C "$(dirname "$DATA")" "$(basename "$DATA")"
mkdir -p "$OUT/$NAME/dsh"
tar -czf "$OUT/$NAME/dsh-home.tar.gz" -C "$(dirname "$DSH")" --exclude="$(basename "$DSH")/sessions" "$(basename "$DSH")"
cp .env "$OUT/$NAME/env.backup" && chmod 600 "$OUT/$NAME/env.backup"
cp docker-compose.yml "$OUT/$NAME/" 2>/dev/null || true
cat > "$OUT/$NAME/README.txt" <<TXT
恢复：bash restore.sh $OUT/$NAME
注意：dsh-home 已排除 sessions（会话历史，可按需手动带）；NapCat 登录态在 qqbot-data 里。
TXT
echo "[backup] 完成：$OUT/$NAME"
