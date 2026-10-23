#!/bin/bash

# 1. 引入公共库并自动计算服务名
# 使用标准的 $0 获取当前脚本的真实绝对路径
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
COMMON_SCRIPT="${SCRIPT_PATH}/../../script/common.sh"

# 检查公共库是否存在
if [ ! -f "$COMMON_SCRIPT" ]; then
    printf "❌ 致命错误: 找不到公共库 %s\n" "$COMMON_SCRIPT"
    exit 1
fi

# 引入公共库
. "$COMMON_SCRIPT"
load_common || exit 1


# 2. 执行初始化（直接生成 $INSTALL_DIR 和 $SERVICE_NAME）
init_service || exit 1

echo "🚀 开始将服务安装到: $SERVICE_DIR"

# 3. 创建数据目录（对应 docker-compose.yml 中的 ./data 与 ./db 挂载）
mkdir -p "$SERVICE_DIR/data" "$SERVICE_DIR/config" "$SERVICE_DIR/logs" "$SERVICE_DIR/plugins" "$SERVICE_DIR/client-plugins" "$SERVICE_DIR/bleve-indexes"
mkdir -p "$SERVICE_DIR/db"

# 容器内进程以 uid/gid 2000 运行，需将挂载目录属主改为 2000:2000
chown 2000:2000 "$SERVICE_DIR/data" "$SERVICE_DIR/config" "$SERVICE_DIR/logs" "$SERVICE_DIR/plugins" "$SERVICE_DIR/client-plugins" "$SERVICE_DIR/bleve-indexes" || {
    printf "❌ 致命错误: 修改目录属主失败，请以 root 运行本脚本\n"
    exit 1
}

# 4. 选择部署方式
choose_install_mode || exit 1

# 5. 安装 docker-compose.yml 并读取配置参数
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
if [ "$INSTALL_MODE" = direct ]; then
    cp "$SCRIPT_PATH/resource/docker-compose.direct.yml" "$COMPOSE_FILE"
else
    cp "$SCRIPT_PATH/resource/docker-compose.yml" "$COMPOSE_FILE"
fi

DEFAULT_POSTGRES_USER="mmuser"

printf "==========================================\n"
printf "⚙️  请配置 Mattermost 运行参数\n"
printf "==========================================\n"

if [ "$INSTALL_MODE" = direct ]; then
    # 直接访问：使用宿主机地址与端口生成绝对访问地址
    ask_direct_host || exit 1
    ask_host_port "Mattermost 访问端口" 8065 || exit 1
    SITE_HOST="$DIRECT_HOST"
    SITE_URL="http://${DIRECT_HOST}:${DIRECT_PORT}"
else
    # 反向代理：域名默认基于 traefik 安装时记录的根域名
    require_root_domain || exit 1
    DEFAULT_SITE_HOST="im.${ROOT_DOMAIN}"
    while true; do
        read -r -p "请输入站点域名 [${DEFAULT_SITE_HOST}]: " SITE_HOST ||
            { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
        SITE_HOST="${SITE_HOST:-$DEFAULT_SITE_HOST}"
        ensure_domain_covered "$SITE_HOST" || continue
        break
    done
    SITE_URL="https://${SITE_HOST}"
fi

read -r -p "请输入数据库用户名 [${DEFAULT_POSTGRES_USER}]: " POSTGRES_USER
POSTGRES_USER="${POSTGRES_USER:-$DEFAULT_POSTGRES_USER}"

printf "请输入数据库密码: "
stty -echo  # 隐藏密码输入
read -r POSTGRES_PASSWORD
stty echo  # 恢复输入
printf "\n"  # 换行，保持输出美观

if [ -z "$POSTGRES_PASSWORD" ]; then
    printf "❌ 致命错误: 数据库密码不能为空\n"
    exit 1
fi

# 6. 拷贝 .env 模板并替换占位符
ENV_FILE=.env
TARGET_ENV_FILE=$SERVICE_DIR/$ENV_FILE
cp "$SCRIPT_PATH/resource/$ENV_FILE" "$TARGET_ENV_FILE"

sed -i "s|__SITE_URL__|$(sed_escape "$SITE_URL")|g" "$TARGET_ENV_FILE"
sed -i "s|__SITE_HOST__|$(sed_escape "$SITE_HOST")|g" "$TARGET_ENV_FILE"
sed -i "s|__POSTGRES_USER__|$(sed_escape "$POSTGRES_USER")|g" "$TARGET_ENV_FILE"
sed -i "s|__POSTGRES_PASSWORD__|$(sed_escape "$POSTGRES_PASSWORD")|g" "$TARGET_ENV_FILE"

if [ "$INSTALL_MODE" = direct ]; then
    sed -i "s|__MATTERMOST_PORT__|$(sed_escape "$DIRECT_PORT")|g" "$TARGET_ENV_FILE"
    open_firewall_ports "$DIRECT_PORT/tcp"
    printf "访问地址: http://%s:%s\n" "$DIRECT_HOST" "$DIRECT_PORT"
else
    sed -i '/^MATTERMOST_PORT=/d' "$TARGET_ENV_FILE"
    printf "访问地址: https://%s（请确认域名已解析到本机并信任 mkcert 根证书）\n" "$SITE_HOST"
fi

echo "✅ $INSTALL_NAME 安装完成！"
