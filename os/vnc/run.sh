#!/bin/bash
###############################################################################
# run.sh — 安装全局 VNC 命令 & 初始化用户配置模板
# 用法: sudo ./run.sh
###############################################################################
set -euo pipefail

# ---------- 加载共享函数库 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

echo "==================== [VNC] ===================="

# [Install]
echo "[VNC] 安装 TigerVNC 服务..."
yum install -y tigervnc-server

VNC_SRC="${SCRIPT_DIR}/resource/vnc"
VNC_USERS_SRC="${SCRIPT_DIR}/resource/vnc-users"
VNC_DST="/usr/bin/vnc"
VNC_USERS_FILE="/etc/vnc-users"

# configure-user.sh 路径（与 run.sh 同目录）
CONF_USER_SCRIPT="${SCRIPT_DIR}/configure-user.sh"

# ---------- 前置依赖检查 ----------
if [[ ! -f "$VNC_SRC" ]]; then
    die "未找到 $VNC_SRC，请确保 resource/vnc 与 run.sh 在同一目录"
fi

if [[ ! -f "$VNC_USERS_SRC" ]]; then
    die "未找到 $VNC_USERS_SRC，请确保 resource/vnc-users 与 run.sh 在同一目录"
fi

echo "[VNC] 安装全局命令: $VNC_SRC → $VNC_DST"
cp -f "$VNC_SRC" "$VNC_DST"
chmod 755 "$VNC_DST"
chown root:root "$VNC_DST"

echo "[VNC] 初始化 /etc/vnc-users"
if [[ ! -f "$VNC_USERS_FILE" ]]; then
    echo "[VNC] 初始化用户配置模板..."
    cp -f "$VNC_USERS_SRC" "$VNC_USERS_FILE"
    chmod 644 "$VNC_USERS_FILE"
    chown root:root "$VNC_USERS_FILE"
    ok "已从模板创建: $VNC_USERS_FILE"
    warn "请编辑 $VNC_USERS_FILE 添加实际用户"
else
    echo "[VNC] /etc/vnc-users 已存在，跳过"
fi

# [Configure] — 调用 configure-user.sh 自动配置每个用户的 VNC 会话
echo "[VNC] 配置现有用户的 VNC 会话..."

if [[ ! -f "$CONF_USER_SCRIPT" ]]; then
    die "未找到 $CONF_USER_SCRIPT，请确保 configure-user.sh 与 run.sh 在同一目录"
fi

list_login_users | while IFS=: read -r username _home; do
    echo ""
    echo ">>> 正在配置用户: $username"
    if bash "$CONF_USER_SCRIPT" "$username"; then
        ok "用户 '$username' VNC 配置完成"
    else
        warn "用户 '$username' VNC 配置失败，请检查"
    fi
done

# [Service]
