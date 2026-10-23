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


# 执行初始化（直接生成 $INSTALL_DIR 和 $SERVICE_NAME）
init_service || exit 1

echo "🚀 开始将服务安装到: $SERVICE_DIR"

mkdir -p "$SERVICE_DIR/data-files" "$SERVICE_DIR/docreader-tmp" "$SERVICE_DIR/config" "$SERVICE_DIR/skills"

# 选择部署方式并安装对应的 docker-compose.yml
choose_install_mode || exit 1
if [ "$INSTALL_MODE" = direct ]; then
    ask_host_port "WeKnora 访问端口" 8080 || exit 1
    COMPOSE_FILE="docker-compose.direct.yml"
else
    require_root_domain || exit 1
    COMPOSE_FILE="docker-compose.yml"
fi
cp resource/$COMPOSE_FILE $SERVICE_DIR/$COMPOSE_FILE

if [ "$INSTALL_MODE" = proxy ]; then
    sed -i "s|km\.sysummit\.internal|$(sed_escape "km.${ROOT_DOMAIN}")|g" "$SERVICE_DIR/$COMPOSE_FILE"
fi

# 安装配置文件
CONFIG_FILE="config.yaml"
cp resource/$CONFIG_FILE $SERVICE_DIR/config/$CONFIG_FILE

# 设置权限
chown -R 1000:1000 $SERVICE_DIR/data-files
chown -R 1000:1000 $SERVICE_DIR/skills
chown -R 1000:1000 $SERVICE_DIR/config
chown -R 1000:1000 $SERVICE_DIR/docreader-tmp

# 安装环境变量
ENV_FILE=".env"
TARGET_ENV_FILE="$SERVICE_DIR/$ENV_FILE"
cp resource/env "$TARGET_ENV_FILE"

if [ "$INSTALL_MODE" = direct ]; then
    sed -i "s|__WEKNORA_PORT__|$(sed_escape "$DIRECT_PORT")|g" "$TARGET_ENV_FILE"
    sed -i "s|^SSRF_WHITELIST=.*|SSRF_WHITELIST=$(sed_escape "$DIRECT_HOST")|" "$TARGET_ENV_FILE"
    open_firewall_ports "$DIRECT_PORT/tcp"
    printf "访问地址: http://<本机IP>:%s\n" "$DIRECT_PORT"
else
    sed -i '/^WEKNORA_PORT=/d' "$TARGET_ENV_FILE"
    sed -i "s|^SSRF_WHITELIST=.*|SSRF_WHITELIST=$(sed_escape "km.${ROOT_DOMAIN}")|" "$TARGET_ENV_FILE"
    printf "访问地址: https://km.%s（请确认域名已解析到本机并信任 mkcert 根证书）\n" "$ROOT_DOMAIN"
fi

echo "✅ $INSTALL_NAME 安装完成！"
