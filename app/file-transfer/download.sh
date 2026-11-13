#!/bin/bash
# ================= file-transfer 离线镜像导出脚本 =================
# 在有互联网的机器上执行：
#   bash app/file-transfer/download.sh
# 生成 assets/file-transfer/file-transfer.tar，随后将整个 assets/file-transfer/
# 目录拷贝到离线目标机器，install.sh 会自动 docker load。

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
ASSETS_DIR="${SCRIPT_PATH}/../../assets/file-transfer"
IMAGE="${FILE_TRANSFER_IMAGE:-rfancn/file-transfer:latest}"
TAR_FILE="${ASSETS_DIR}/file-transfer.tar"

command -v docker >/dev/null 2>&1 || {
    printf "❌ 未找到 docker 命令，请先安装 Docker。\n" >&2
    exit 1
}

mkdir -p "$ASSETS_DIR"

printf "⬇️  正在拉取镜像: %s\n" "$IMAGE"
docker pull "$IMAGE"

printf "📦 正在导出镜像到: %s\n" "$TAR_FILE"
docker save -o "$TAR_FILE" "$IMAGE"

printf "✅ 完成: %s (%s)\n" "$TAR_FILE" "$(du -sh "$TAR_FILE" | cut -f1)"
printf "   请将 assets/file-transfer/ 目录拷贝到离线机器后执行 install.sh。\n"
