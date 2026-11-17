#!/bin/bash
# ================= rustfs 离线镜像导出脚本 =================
# 在有互联网的机器上执行：
#   sh run.sh download rustfs
# 生成 assets/rustfs/rustfs.tar，随后将整个 assets/rustfs/
# 目录拷贝到离线目标机器，install.sh 会自动 docker load。

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
ASSETS_DIR="${SCRIPT_PATH}/../../assets/rustfs"
IMAGE="${RUSTFS_IMAGE:-rustfs/rustfs:latest}"
TAR_FILE="${ASSETS_DIR}/rustfs.tar"

command -v docker >/dev/null 2>&1 || {
    printf "❌ 未找到 docker 命令，请先安装 Docker。\n" >&2
    exit 1
}

mkdir -p "$ASSETS_DIR"

# 本地优先：已有镜像直接导出，避免不必要的联网拉取
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf "📦 使用本地镜像: %s\n" "$IMAGE"
else
    printf "⬇️  本地未找到镜像，正在拉取: %s\n" "$IMAGE"
    docker pull "$IMAGE"
fi

printf "📦 正在导出镜像到: %s\n" "$TAR_FILE"
docker save -o "$TAR_FILE" "$IMAGE"

printf "✅ 完成: %s (%s)\n" "$TAR_FILE" "$(du -sh "$TAR_FILE" | cut -f1)"
printf "   请将 assets/rustfs/ 目录拷贝到离线机器后执行 install.sh。\n"