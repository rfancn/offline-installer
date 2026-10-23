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
mkdir -p "$SERVICE_DIR/data" "$SERVICE_DIR/db"

# 选择部署方式并安装对应的 docker-compose.yml
choose_install_mode || exit 1
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
if [ "$INSTALL_MODE" = direct ]; then
    ask_host_port "ZenTao 访问端口" 8080 || exit 1
    cp resource/docker-compose.direct.yml "$COMPOSE_FILE"
else
    require_root_domain || exit 1
    cp resource/docker-compose.yml "$COMPOSE_FILE"
    sed -i "s|bug\.sysummit\.internal|$(sed_escape "bug.${ROOT_DOMAIN}")|g" "$COMPOSE_FILE"
fi

# 数据库密码：同时供 MySQL 容器与 ZenTao 容器使用，写入服务目录的 .env
gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 5
    else
        od -An -N5 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

while true; do
    printf "请输入 MySQL root 密码（至少 8 位，回车自动生成 10 位随机密码）: "
    stty -echo
    read -r MYSQL_ROOT_PASSWORD || {
        stty echo
        printf "\n❌ 输入已结束（EOF），已中止。\n" >&2
        exit 1
    }
    stty echo
    printf "\n"

    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        MYSQL_ROOT_PASSWORD="$(gen_password)"
        printf "✅ 已自动生成随机密码\n"
        break
    fi
    if [ ${#MYSQL_ROOT_PASSWORD} -lt 8 ]; then
        printf "❌ 密码至少 8 位，请重新输入。\n"
        continue
    fi
    # 避免破坏 .env 解析：仅允许字母、数字与 . _ @ %% + -
    case "$MYSQL_ROOT_PASSWORD" in
        *[!A-Za-z0-9._@%+-]*)
            printf "❌ 密码只能包含字母、数字与 . _ @ %% + -，请重新输入。\n"
            continue
            ;;
    esac
    break
done

TARGET_ENV_FILE="$SERVICE_DIR/.env"
cp resource/env "$TARGET_ENV_FILE"
sed -i "s|__MYSQL_ROOT_PASSWORD__|$(sed_escape "$MYSQL_ROOT_PASSWORD")|g" "$TARGET_ENV_FILE"
chmod 600 "$TARGET_ENV_FILE"

if [ "$INSTALL_MODE" = direct ]; then
    sed -i "s|__ZENTAO_PORT__|$(sed_escape "$DIRECT_PORT")|g" "$TARGET_ENV_FILE"
    open_firewall_ports "$DIRECT_PORT/tcp"
    printf "访问地址: http://<本机IP>:%s\n" "$DIRECT_PORT"
else
    sed -i '/^ZENTAO_PORT=/d' "$TARGET_ENV_FILE"
    printf "访问地址: https://bug.%s（请确认域名已解析到本机并信任 mkcert 根证书）\n" "$ROOT_DOMAIN"
fi

echo "✅ $INSTALL_NAME 安装完成！"
