#!/bin/bash

# 1. 引入公共库并自动计算服务名
# 使用标准的 $0 获取当前脚本的真实绝对路径
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
# 统一入口 run.sh 可能从任意目录调起，切换到脚本目录以保证 resource/ 相对路径有效
cd "$SCRIPT_PATH" || exit 1
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

mkdir -p "$SERVICE_DIR/conf" "$SERVICE_DIR/resources" "$SERVICE_DIR/db" "$SERVICE_DIR/logs" "$SERVICE_DIR/upload"

# 选择部署方式：反向代理需要根域名，直接访问需要宿主机端口
choose_install_mode || exit 1
if [ "$INSTALL_MODE" = direct ]; then
    ask_host_port "AirPress 访问端口" 8080 || exit 1
else
    require_root_domain || exit 1
fi

# 安装docker-compose.yml
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
if [ "$INSTALL_MODE" = direct ]; then
    cp resource/docker-compose.direct.yml "$COMPOSE_FILE"
else
    cp resource/docker-compose.yml "$COMPOSE_FILE"
    sed -i "s|www\.sysummit\.internal|$(sed_escape "www.${ROOT_DOMAIN}")|g" "$COMPOSE_FILE"
fi

ENV_FILE=.env
TARGET_ENV_FILE=$SERVICE_DIR/$ENV_FILE
cp resource/$ENV_FILE $TARGET_ENV_FILE

if [ "$INSTALL_MODE" = direct ]; then
    sed -i "s|__AIRPRESS_PORT__|$(sed_escape "$DIRECT_PORT")|g" "$TARGET_ENV_FILE"
else
    sed -i '/^AIRPRESS_PORT=/d' "$TARGET_ENV_FILE"
fi

CONFIG_FILE=conf/config.yaml
TARGET_CONFIG_FILE=$SERVICE_DIR/$CONFIG_FILE

cp resource/$CONFIG_FILE $TARGET_CONFIG_FILE 

# 安装主题
THEME_NAME=theme-simple-corp-portal
TARGET_THEME_DIR="$SERVICE_DIR/resources/template/theme"
mkdir -p $TARGET_THEME_DIR
cp -fr resource/$THEME_NAME $TARGET_THEME_DIR 

printf "==========================================\n"
printf "🔐 请配置数据库密码\n"
printf "==========================================\n"
printf "请输入数据库密码: "
stty -echo  # 隐藏密码输入
read -r MYSQL_PASSWORD
stty echo  # 恢复输入
printf "\n"  # 换行，保持输出美观

sed -i "s|__MYSQL_PASSWORD__|${MYSQL_PASSWORD}|g" "$TARGET_CONFIG_FILE"
sed -i "s|__MYSQL_PASSWORD__|${MYSQL_PASSWORD}|g" "$TARGET_ENV_FILE"

# 直接访问模式放行宿主机端口
if [ "$INSTALL_MODE" = direct ]; then
    open_firewall_ports "$DIRECT_PORT/tcp"
    printf "访问地址: http://<本机IP>:%s\n" "$DIRECT_PORT"
else
    printf "访问地址: https://www.%s（请确认域名已解析到本机并信任 mkcert 根证书）\n" "$ROOT_DOMAIN"
fi

echo "✅ $INSTALL_NAME 安装完成！"

