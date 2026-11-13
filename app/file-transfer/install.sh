#!/bin/bash

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
# 统一入口 run.sh 可能从任意目录调起，切换到脚本目录以保证 resource/ 相对路径有效
cd "$SCRIPT_PATH" || exit 1
COMMON_SCRIPT="${SCRIPT_PATH}/../../script/common.sh"

if [ ! -f "$COMMON_SCRIPT" ]; then
    printf "❌ 致命错误: 找不到公共库 %s\n" "$COMMON_SCRIPT"
    exit 1
fi

. "$COMMON_SCRIPT"
load_common || exit 1

# ================= 离线镜像 =================
IMAGE="rfancn/file-transfer:latest"
IMAGE_TAR="$SCRIPT_PATH/../../assets/file-transfer/file-transfer.tar"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    if [ -f "$IMAGE_TAR" ]; then
        printf "📦 正在加载离线镜像: %s\n" "$IMAGE_TAR"
        docker load -i "$IMAGE_TAR" || {
            printf "❌ 镜像加载失败: %s\n" "$IMAGE_TAR"
            exit 1
        }
    else
        printf "❌ 未找到本地镜像，且离线镜像包不存在: %s\n" "$IMAGE_TAR"
        printf "   请在有网机器执行 app/file-transfer/download.sh 生成后拷贝到本机。\n"
        exit 1
    fi
fi

# 执行初始化（直接生成 $SERVICE_DIR 和 $SERVICE_NAME）
init_service || exit 1

echo "🚀 开始将服务安装到: $SERVICE_DIR"

# 创建持久化目录：配置、密钥、日志
for d in config logs secrets; do
    mkdir -p "$SERVICE_DIR/$d" || {
        printf "❌ 致命错误: 创建目录失败: %s/%s\n" "$SERVICE_DIR" "$d"
        exit 1
    }
done

# 生成 URL 安全的强随机密钥
rand_secret() {
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'
}

# ================= 部署方式 =================
choose_install_mode || exit 1
if [ "$INSTALL_MODE" = direct ]; then
    ask_host_port "file-transfer 访问端口" 8080 || exit 1
    COMPOSE_SRC="docker-compose.direct.yml"
else
    require_root_domain || exit 1
    DEFAULT_SITE_HOST="ft.${ROOT_DOMAIN}"
    printf "==========================================\n"
    printf "🌐 请配置 Traefik 访问域名\n"
    printf "==========================================\n"
    while true; do
        printf "请输入域名（如 ft.example.com）[%s]: " "$DEFAULT_SITE_HOST"
        read -r SITE_HOST || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
        SITE_HOST="${SITE_HOST:-$DEFAULT_SITE_HOST}"
        ensure_domain_covered "$SITE_HOST" || continue
        break
    done
    COMPOSE_SRC="docker-compose.yml"
fi

# ================= 服务端配置 =================
while true; do
    read_default "RustFS S3 Endpoint" "http://rustfs:9000" S3_ENDPOINT || exit 1
    case "$S3_ENDPOINT" in
        http://*|https://*) break ;;
        *) printf "❌ Endpoint 必须以 http:// 或 https:// 开头，请重新输入。\n" >&2 ;;
    esac
done

TOKEN_SECRET="$(rand_secret)"
UPLOAD_SECRET="$(rand_secret)"
if [ -z "$TOKEN_SECRET" ] || [ -z "$UPLOAD_SECRET" ]; then
    printf "❌ 致命错误: 随机密钥生成失败\n"
    exit 1
fi

CONFIG_FILE="$SERVICE_DIR/config/ft-server.toml"
cp resource/ft-server.example.toml "$CONFIG_FILE" || {
    printf "❌ 致命错误: 无法写入 %s\n" "$CONFIG_FILE"
    exit 1
}
sed -i "s|__S3_ENDPOINT__|$(sed_escape "$S3_ENDPOINT")|g" "$CONFIG_FILE"
sed -i "s|__TOKEN_SECRET__|$(sed_escape "$TOKEN_SECRET")|g" "$CONFIG_FILE"
sed -i "s|__UPLOAD_SECRET__|$(sed_escape "$UPLOAD_SECRET")|g" "$CONFIG_FILE"
# 配置中包含认证密钥，仅允许当前用户读写
chmod 600 "$CONFIG_FILE"

# ================= 安装 compose 与环境变量 =================
cp "resource/$COMPOSE_SRC" "$SERVICE_DIR/docker-compose.yml"

ENV_FILE="$SERVICE_DIR/.env"
cp resource/env "$ENV_FILE"
if [ "$INSTALL_MODE" = direct ]; then
    sed -i "s|__FT_PORT__|$(sed_escape "$DIRECT_PORT")|g" "$ENV_FILE"
    sed -i '/^SITE_HOST=/d' "$ENV_FILE"
    open_firewall_ports "$DIRECT_PORT/tcp"
else
    sed -i "s|__SITE_HOST__|$(sed_escape "$SITE_HOST")|g" "$ENV_FILE"
    sed -i '/^FT_PORT=/d; /^# 直接访问模式的宿主机端口/d' "$ENV_FILE"
fi

# ================= 完成提示 =================
printf "==========================================\n"
printf "✅ %s 安装完成！\n" "$INSTALL_NAME"
printf "📂 安装目录: %s\n" "$SERVICE_DIR"
if [ "$INSTALL_MODE" = direct ]; then
    printf "🌐 访问地址: http://<本机IP>:%s\n" "$DIRECT_PORT"
    printf "🌐 本机端口: http://127.0.0.1:%s\n" "$DIRECT_PORT"
else
    printf "🌐 访问地址: https://%s\n" "$SITE_HOST"
fi
printf "🔐 token_secret / upload_secret 已随机生成: %s\n" "$CONFIG_FILE"
printf "👤 首次启动将生成管理员账号 admin，密码见 %s/secrets/user.json 或容器日志。\n" "$SERVICE_DIR"
printf "🔗 RustFS 地址: %s\n" "$S3_ENDPOINT"
printf "下一步：cd %s && docker compose up -d\n" "$SERVICE_DIR"
printf "==========================================\n"
