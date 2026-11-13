#!/bin/bash

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_PATH" || exit 1
COMMON_SCRIPT="${SCRIPT_PATH}/../../script/common.sh"

if [ ! -f "$COMMON_SCRIPT" ]; then
    printf "❌ 致命错误: 找不到公共库 %s\n" "$COMMON_SCRIPT"
    exit 1
fi

. "$COMMON_SCRIPT"
load_common || exit 1

init_service || exit 1

echo "🚀 开始将服务安装到: $SERVICE_DIR"

mkdir -p "$SERVICE_DIR/data" "$SERVICE_DIR/logs"

# 容器内进程以 uid/gid 10001 运行，需将 data/logs 目录属主改为 10001:10001
chown 10001:10001 "$SERVICE_DIR/data" "$SERVICE_DIR/logs" || {
    printf "❌ 致命错误: 修改 data/logs 目录属主失败，请以 root 运行本脚本\n"
    exit 1
}

# ================= 离线资源 =================
ASSETS_DIR="${SCRIPT_PATH}/../../assets/rustfs"

# 导入 rustfs 镜像
if [ -f "$ASSETS_DIR/rustfs.tar" ]; then
    printf "📦 导入 rustfs 镜像: %s\n" "$ASSETS_DIR/rustfs.tar"
    if ! command -v docker >/dev/null 2>&1; then
        printf "❌ 未找到 docker，无法导入镜像\n"
        exit 1
    fi
    if ! docker load -i "$ASSETS_DIR/rustfs.tar"; then
        printf "❌ 导入 rustfs 镜像失败\n"
        exit 1
    fi
else
    printf "⚠️ 未找到 %s/rustfs.tar，将依赖本地镜像或在线拉取\n" "$ASSETS_DIR"
fi
# ==========================================

# 生成 URL 安全的强随机密钥（用于 root 账号）
rand_strong_secret() {
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'
}

# 交互读取域名前缀（结果写入第 3 个参数指定的变量）
# 参数: $1=提示文案 $2=默认值 $3=结果变量名
read_prefix() {
    local label="$1" default="$2" result_var="$3" p
    while true; do
        printf "请输入%s [%s]: " "$label" "$default"
        read -r p || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        p="${p:-$default}"
        case "$p" in
            -*|*-|*[!a-z0-9-]*)
                printf "❌ 前缀只能包含小写字母、数字和连字符，且不能以连字符开头或结尾。\n" >&2
                continue ;;
        esac
        printf -v "$result_var" '%s' "$p"
        return 0
    done
}

choose_install_mode || exit 1

# 生成所有凭据
RUSTFS_ACCESS_KEY="root"
RUSTFS_SECRET_KEY="$(rand_strong_secret)"

if [ "$INSTALL_MODE" = direct ]; then
    ask_direct_host || exit 1
    ask_host_port "S3 API 端口" 9000 || exit 1
    S3_PORT="$DIRECT_PORT"
    ask_host_port "Console 端口" 9001 || exit 1
    CONSOLE_PORT="$DIRECT_PORT"
    if [ "$S3_PORT" = "$CONSOLE_PORT" ]; then
        printf "❌ S3 API 与 Console 端口不能相同。\n" >&2
        exit 1
    fi
    cp resource/docker-compose.direct.yml "$SERVICE_DIR/docker-compose.yml"
    S3_ENDPOINT="http://${DIRECT_HOST}:${S3_PORT}"
else
    require_root_domain || exit 1
    read_prefix "Console 域名前缀" "oss" CONSOLE_PREFIX || exit 1
    CONSOLE_HOST="${CONSOLE_PREFIX}.${ROOT_DOMAIN}"
    ensure_domain_covered "$CONSOLE_HOST" || exit 1
    S3_PORT=9000
    CONSOLE_PORT=9001
    cp resource/docker-compose.yml "$SERVICE_DIR/docker-compose.yml"
    sed -i "s|__CONSOLE_HOST__|$(sed_escape "$CONSOLE_HOST")|g" "$SERVICE_DIR/docker-compose.yml"
    S3_ENDPOINT="http://rustfs:9000"
fi

# 渲染 .env
ENV_FILE="$SERVICE_DIR/.env"
cp resource/.env "$ENV_FILE"
sed -i "s|__RUSTFS_ACCESS_KEY__|$(sed_escape "$RUSTFS_ACCESS_KEY")|g" "$ENV_FILE"
sed -i "s|__RUSTFS_SECRET_KEY__|$(sed_escape "$RUSTFS_SECRET_KEY")|g" "$ENV_FILE"
sed -i "s|__RUSTFS_S3_PORT__|$(sed_escape "$S3_PORT")|g" "$ENV_FILE"
sed -i "s|__RUSTFS_CONSOLE_PORT__|$(sed_escape "$CONSOLE_PORT")|g" "$ENV_FILE"
chmod 600 "$ENV_FILE"

printf -- "----------------------------------------\n"
if [ "$INSTALL_MODE" = direct ]; then
    printf "S3 API:  %s\n" "$S3_ENDPOINT"
    printf "Console: http://%s:%s\n" "$DIRECT_HOST" "$CONSOLE_PORT"
    open_firewall_ports "$S3_PORT/tcp" "$CONSOLE_PORT/tcp"
else
    printf "S3 API:  %s（仅容器网络内可访问）\n" "$S3_ENDPOINT"
    printf "Console: https://%s\n" "$CONSOLE_HOST"
    printf "⚠️  请确认 Console 域名已解析到本机，并在客户端信任 mkcert 根证书。\n"
fi
printf -- "----------------------------------------\n"
printf "root 凭据（仅用于初始化）:\n"
printf "  Access Key: %s\n" "$RUSTFS_ACCESS_KEY"
printf "  Secret Key: %s\n" "$RUSTFS_SECRET_KEY"
printf -- "----------------------------------------\n"
printf "下一步：cd %s\n" "$SERVICE_DIR"
printf "  docker compose up -d\n"
echo "✅ $INSTALL_NAME 安装完成！"