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


# 创建相关目录
mkdir -p "$SERVICE_DIR/config" "$SERVICE_DIR/logs" "$SERVICE_DIR/data"

# 选择部署方式并安装对应的 docker-compose.yml
choose_install_mode || exit 1
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
if [ "$INSTALL_MODE" = direct ]; then
    ask_direct_host || exit 1
    ask_host_port "GitLab 访问端口" 8929 || exit 1
    cp resource/docker-compose.direct.yml "$COMPOSE_FILE"

    TARGET_ENV_FILE="$SERVICE_DIR/.env"
    cp resource/.env "$TARGET_ENV_FILE"
    sed -i "s|__GITLAB_HOST__|$(sed_escape "$DIRECT_HOST")|g" "$TARGET_ENV_FILE"
    sed -i "s|__GITLAB_HTTP_PORT__|$(sed_escape "$DIRECT_PORT")|g" "$TARGET_ENV_FILE"
    sed -i "s|__GITLAB_EXTERNAL_URL__|$(sed_escape "http://${DIRECT_HOST}:${DIRECT_PORT}")|g" "$TARGET_ENV_FILE"
else
    require_root_domain || exit 1
    cp resource/docker-compose.yml "$COMPOSE_FILE"
    sed -i "s|git\.sysummit\.internal|$(sed_escape "git.${ROOT_DOMAIN}")|g" "$COMPOSE_FILE"
fi

###############
# 调整内核参数
###############
# 1. 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    printf "❌ 错误: 修改系统资源限制需要 root 权限，请使用 sudo 运行！\n"
    exit 1
fi

LIMITS_FILE="/etc/security/limits.conf"
MARKER="# === Custom Limits for GitLab/Docker ==="

# 2. 检查是否已经配置过（防止重复追加）
if grep -q "$MARKER" "$LIMITS_FILE"; then
    printf "✅ 检测到系统资源限制已配置，跳过修改。\n"
else
    # 3. 追加配置到 limits.conf
    printf "⚙️  正在配置系统资源限制...\n"
    cat >> "$LIMITS_FILE" << EOF

$MARKER
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
* soft sigpending 65535
* hard sigpending 65535
EOF

    # 4. 检查写入是否成功
    if [ $? -eq 0 ]; then
        printf "✅ 系统资源限制配置成功！\n"
        printf "⚠️  注意: 请重新登录当前用户或重启系统，配置才会生效。\n"
    else
        printf "❌ 写入 $LIMITS_FILE 失败，请检查文件权限。\n"
        exit 1
    fi
fi

if [ "$INSTALL_MODE" = direct ]; then
    open_firewall_ports "$DIRECT_PORT/tcp"
    printf "访问地址: http://%s:%s\n" "$DIRECT_HOST" "$DIRECT_PORT"
else
    printf "访问地址: https://git.%s（请确认域名已解析到本机并信任 mkcert 根证书）\n" "$ROOT_DOMAIN"
fi

echo "✅ $INSTALL_NAME 安装完成！"
