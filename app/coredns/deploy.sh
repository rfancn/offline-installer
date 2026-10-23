#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ==================== 用法检查 ====================
usage() {
    echo "用法: $0 <primary|secondary> [coredns-<version>.tar.gz]"
    echo ""
    echo "  <primary|secondary>    部署 CoreDNS 主节点或从节点"
    echo "  [coredns-<version>.tar.gz]  指定构建产物路径（可选，默认从 dist/ 自动查找）"
    echo ""
    echo "  示例:"
    echo "    $0 primary"
    echo "    $0 primary ./dist/coredns-v1.14.7.tar.gz"
    echo "    $0 secondary /path/to/coredns-v1.14.7.tar.gz"
    exit 1
}

if [ $# -lt 1 ]; then
    echo "错误: 必须指定节点角色"
    usage
fi

ROLE="$1"
if [[ "${ROLE}" != "primary" && "${ROLE}" != "secondary" ]]; then
    echo "错误: 未知角色 '${ROLE}'，仅支持 primary 或 secondary"
    usage
fi

# 构建产物路径：参数指定 或 自动查找
if [ $# -ge 2 ]; then
    BUILD_ARTIFACT="$2"
else
    # 在 dist/ 目录下查找最新的 coredns-*.tar.gz
    BUILD_ARTIFACT=$(find "${SCRIPT_DIR}/dist" -name "coredns-*.tar.gz" -type f 2>/dev/null | sort -r | head -n 1)
fi

if [ -z "${BUILD_ARTIFACT}" ] || [ ! -f "${BUILD_ARTIFACT}" ]; then
    echo "错误: 未找到构建产物"
    if [ $# -lt 2 ]; then
        echo "  请在 dist/ 目录下确认存在 coredns-*.tar.gz 文件，或直接指定路径:"
        echo "    $0 primary /path/to/coredns-<version>.tar.gz"
    else
        echo "  指定文件不存在: ${BUILD_ARTIFACT}"
    fi
    exit 1
fi

echo ""
echo "==> CoreDNS 部署脚本"
echo "    角色:         ${ROLE}"
echo "    构建产物:     ${BUILD_ARTIFACT}"
echo ""

# ==================== 加载 .env ====================
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "${ENV_FILE}" ]; then
    echo "==> 加载环境变量: ${ENV_FILE}"
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
else
    echo "==> 提示: 未找到 .env 文件，使用默认值或系统环境变量"
fi

# ==================== 公共配置 ====================
PRIMARY_IP="${PRIMARY_IP:-192.168.2.10}"
SECONDARY_IP="${SECONDARY_IP:-192.168.2.11}"
DOMAIN="${DOMAIN:-example.com}"
CONFIG_DIR="${CONFIG_DIR:-/etc/coredns}"
COREDNS_VERSION="${COREDNS_VERSION:-1.14.7}"
ZONES_DIR="${CONFIG_DIR}/zones"

export PRIMARY_IP SECONDARY_IP DOMAIN CONFIG_DIR COREDNS_VERSION
# ================================================

echo "    PRIMARY_IP:   ${PRIMARY_IP}"
echo "    SECONDARY_IP: ${SECONDARY_IP}"
echo "    DOMAIN:       ${DOMAIN}"
echo "    CONFIG_DIR:   ${CONFIG_DIR}"
echo "    ZONES_DIR:    ${ZONES_DIR}"
echo ""

# ==================== 解压构建产物 ====================
EXTRACT_DIR="${SCRIPT_DIR}/.deploy-extract"
trap 'rm -rf "${EXTRACT_DIR}"' EXIT

rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"

echo "==> 解压构建产物: ${BUILD_ARTIFACT}"
tar -xzf "${BUILD_ARTIFACT}" -C "${EXTRACT_DIR}"

LOCAL_ZONES_DIR="${EXTRACT_DIR}/zones"
COMPOSE_TEMPLATE="${EXTRACT_DIR}/docker-compose.${ROLE}.yml"
IMAGE_TAR_FILE=$(find "${EXTRACT_DIR}" -name "image.tar" -type f 2>/dev/null | head -n 1)

if [ ! -d "${LOCAL_ZONES_DIR}" ]; then
    echo "错误: 构建产物中缺少 zones 目录"
    exit 1
fi

if [ ! -f "${COMPOSE_TEMPLATE}" ]; then
    echo "错误: 构建产物中缺少 docker-compose.${ROLE}.yml"
    exit 1
fi

if [ -z "${IMAGE_TAR_FILE}" ]; then
    echo "错误: 构建产物中未找到 Docker 镜像文件 (coredns-v*.tar)"
    exit 1
fi

LOCAL_ZONE_COUNT=$(find "${LOCAL_ZONES_DIR}" -type f ! -name '.*' | wc -l)
echo "==> 构建产物: ${LOCAL_ZONE_COUNT} 个 zone 文件, compose 模板: docker-compose.${ROLE}.yml"

# ==================== 加载 Docker 镜像 ====================
echo "==> 加载 Docker 镜像: ${IMAGE_TAR_FILE}"
docker load -i "${IMAGE_TAR_FILE}"

# 从文件名提取版本号
IMAGE_TAG="coredns:${COREDNS_VERSION}"

# 验证镜像加载成功
if docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
    echo "✅ 镜像加载成功: ${IMAGE_TAG}"
else
    echo " 镜像加载失败或标签不匹配!"
    echo "   期望标签: ${IMAGE_TAG}"
    echo "   可用 coredns 镜像:"
    docker images | grep coredns || echo "   (无)"
    exit 1
fi
echo ""

# ==================== 1. 创建目录 ====================
echo "==> 创建目录: ${ZONES_DIR}"
mkdir -p "${ZONES_DIR}"

# ==================== 2. 同步 zones（仅 primary） ====================
if [ "${ROLE}" = "primary" ]; then
    echo "==> 同步 zones -> ${ZONES_DIR}/"
    if command -v rsync &>/dev/null; then
        rsync -av --exclude='.*' "${LOCAL_ZONES_DIR}/" "${ZONES_DIR}/"
    else
        find "${ZONES_DIR}" -mindepth 1 -type f ! -name '.*' -delete 2>/dev/null || true
        cp -r "${LOCAL_ZONES_DIR}/"* "${ZONES_DIR}/" 2>/dev/null || true
    fi

    # 默认 zone（zones 目录为空时生成）
    ZONE_FILES_COUNT=$(find "${ZONES_DIR}" -maxdepth 1 -type f ! -name '.*' | wc -l)
    if [ "${ZONE_FILES_COUNT}" -eq 0 ]; then
        DEFAULT_ZONE="${ZONES_DIR}/${DOMAIN}"
        echo "==> zones 为空，生成默认 zone: ${DEFAULT_ZONE}"
        cat > "${DEFAULT_ZONE}" <<EOF
\$TTL 3600
\$ORIGIN ${DOMAIN}.
@       IN      SOA     ns1.${DOMAIN}. admin.${DOMAIN}. (
                        $(date +%Y%m%d)01 ; Serial
                        3600            ; Refresh
                        900             ; Retry
                        604800          ; Expire
                        86400 )         ; Minimum TTL
@               IN      NS      ns1.${DOMAIN}.
@               IN      NS      ns2.${DOMAIN}.
ns1             IN      A       ${PRIMARY_IP}
ns2             IN      A       ${SECONDARY_IP}
@               IN      A       ${PRIMARY_IP}
www             IN      A       ${PRIMARY_IP}
EOF
    else
        echo "==> zones 已有 ${ZONE_FILES_COUNT} 个文件，跳过默认生成"
    fi
else
    echo "==> Secondary 模式，跳过 zones 同步（通过区域传输获取）"
fi

# ==================== 3. 生成 Corefile ====================
if [ "${ROLE}" = "primary" ]; then
    echo "==> 生成 Primary Corefile"

    # 动态构建 file 指令行
    FILE_DIRECTIVES=""
    for zone_file in "${ZONES_DIR}"/*; do
        [ -f "$zone_file" ] || continue
        filename="$(basename "$zone_file")"
        # 从文件名提取 zone 名（支持 db.xxx 和 xxx 两种命名）
        zone_name="${filename#db.}"
        FILE_DIRECTIVES+="file ${ZONES_DIR}/${filename} ${zone_name}"$'\n'
    done

    # 如果没有找到任何 zone 文件，使用默认
    if [ -z "${FILE_DIRECTIVES}" ]; then
        FILE_DIRECTIVES="file ${ZONES_DIR}/${DOMAIN} ${DOMAIN}"
    fi


    cat > "${CONFIG_DIR}/Corefile" <<EOF
${DOMAIN}:53 {
    log
    errors
    health {
        lameduck 5s
    }
    ready
    prometheus :9153
    ${FILE_DIRECTIVES}
    transfer {
        to ${SECONDARY_IP}
    }
    reload
}

.:53 {
    forward . /etc/resolv.conf
    log
    errors
}
EOF
else
    echo "==> 生成 Secondary Corefile"
    cat > "${CONFIG_DIR}/Corefile" <<EOF
${DOMAIN}:53 {
    log
    errors
    health {
        lameduck 5s
    }
    ready
    prometheus :9153
    secondary ${DOMAIN} {
        transfer from ${PRIMARY_IP}
    }
    reload
}

.:53 {
    forward . /etc/resolv.conf
    log
    errors
}
EOF
fi

echo "==> Corefile:"
sed 's/^/    /' "${CONFIG_DIR}/Corefile"
echo ""

# ==================== 4. 渲染 docker-compose.yml ====================
echo "==> 渲染 docker-compose.${ROLE}.yml -> ${CONFIG_DIR}/docker-compose.yml"
envsubst < "${COMPOSE_TEMPLATE}" > "${CONFIG_DIR}/docker-compose.yml"

echo "==> docker-compose.yml:"
sed 's/^/    /' "${CONFIG_DIR}/docker-compose.yml"
echo ""

# ==================== 5. 启动容器 ====================
echo "==> 启动 CoreDNS 容器..."
cd "${CONFIG_DIR}"
docker compose up -d ${ROLE}

# ==================== 6. 完成 ====================
if [ "${ROLE}" = "primary" ]; then
    LISTEN_IP="${PRIMARY_IP}"
else
    LISTEN_IP="${SECONDARY_IP}"
fi

echo ""
echo "✅ 部署完成！"
echo "   角色:   ${ROLE}"
echo "   域名:   ${DOMAIN}"
echo "   监听:   ${LISTEN_IP}:53"
echo "   镜像:   ${IMAGE_TAG}"
echo "   配置:   ${CONFIG_DIR}/Corefile"
echo "   Zones:  ${ZONES_DIR}/"
echo ""
echo "   常用命令:"
echo "   查看状态: docker compose -f ${CONFIG_DIR}/docker-compose.yml ps"
echo "   查看日志: docker compose -f ${CONFIG_DIR}/docker-compose.yml logs -f"
echo "   测试解析: dig @${LISTEN_IP} www.${DOMAIN}"
