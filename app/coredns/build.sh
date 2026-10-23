#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
RESOURCE_DIR="${SCRIPT_DIR}/resource"

# ==========================================
# 1. 加载 .env 并校验版本
# ==========================================
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  source "${SCRIPT_DIR}/.env"
  set +a
fi

if [[ -z "${COREDNS_VERSION:-}" ]]; then
  echo "❌ 错误: COREDNS_VERSION 未设置"
  echo "   请在 .env 文件中添加: COREDNS_VERSION=x.x.x"
  exit 1
fi

echo "📌 CoreDNS 版本: v${COREDNS_VERSION}"

# ==========================================
# 2. 构建 Docker 镜像
# ==========================================
IMAGE_NAME="coredns:${COREDNS_VERSION}"

echo "🐳 正在构建镜像: ${IMAGE_NAME}"
docker build \
  --build-arg COREDNS_VERSION="${COREDNS_VERSION}" \
  -t "${IMAGE_NAME}" \
  -f "${SCRIPT_DIR}/Dockerfile" \
  "${SCRIPT_DIR}"

# ==========================================
# 3. 组装最终交付包（image.tar + resource/* 同层级）
# ==========================================
PACK_TMP="${DIST_DIR}/_pack_tmp"
rm -rf "${PACK_TMP}"
mkdir -p "${PACK_TMP}"

# 3a. 导出镜像（固定文件名 image.tar）
echo "💾 正在导出镜像: image.tar"
docker save -o "${PACK_TMP}/image.tar" "${IMAGE_NAME}"
echo "✅ 镜像已导出 ($(du -h "${PACK_TMP}/image.tar" | cut -f1))"

# 3b. 复制 resource/ 下所有文件到同级目录
if [[ -d "${RESOURCE_DIR}" ]] && [[ "$(ls -A "${RESOURCE_DIR}" 2>/dev/null)" ]]; then
  echo "📁 正在复制 resource/ 内容到打包目录..."
  cp -a "${RESOURCE_DIR}"/. "${PACK_TMP}/"
  echo "✅ resource/ 内容已复制"
else
  echo "❌ resource/ 目录不存在或为空，无法继续"
  exit 1
fi

# 3c. 打包为最终 .tar.gz
FINAL_ARCHIVE="${DIST_DIR}/coredns-${COREDNS_VERSION}.tar.gz"
echo "📦 正在生成最终交付包: $(basename "${FINAL_ARCHIVE}")"
tar -czf "${FINAL_ARCHIVE}" -C "${PACK_TMP}" .
echo "✅ 交付包就绪: ${FINAL_ARCHIVE} ($(du -h "${FINAL_ARCHIVE}" | cut -f1))"

# ==========================================
# 4. 清理临时目录
# ==========================================
rm -rf "${PACK_TMP}"

# ==========================================
# 5. 汇总输出
# ==========================================
echo ""
echo "=========================================="
echo "✅ 构建完成!"
echo "   交付包: dist/coredns-${COREDNS_VERSION}.tar.gz"
echo ""
echo "📋 deploy.sh 使用方式:"
echo "   tar -xzf dist/coredns-${COREDNS_VERSION}.tar.gz -C /target/dir"
echo "   cd /target/dir"
echo "   cp .env.example .env   # 按需修改配置"
echo "   docker load -i image.tar"
echo "=========================================="
