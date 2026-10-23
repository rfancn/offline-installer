#!/bin/bash
# run.sh — 安装并配置 XRDP 远程桌面服务（xrdp + xorgxrdp 配合使用）
set -euo pipefail

# ---------- 加载共享函数库 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

OS_VERSION=$(rpm -E %{rhel})
echo "==================== [XRDP] ===================="

# [Install]
echo "[XRDP] 安装 XRDP 服务及 xorgxrdp 后端..."
yum install -y xrdp xorgxrdp

# [Configure]
echo "[XRDP] 配置 sesman.ini 使用 xorgxrdp 后端（替代默认 Xvnc）..."
TARGET_SESMAN_INI="/etc/xrdp/sesman.ini"
SRC_SESMAN_INI="${SCRIPT_DIR}/resource/sesman.ini"
if [[ -f "$TARGET_SESMAN_INI" ]]; then
    # 备份原始配置
    cp "$TARGET_SESMAN_INI" "${TARGET_SESMAN_INI}.$$"
fi
cp "$SRC_SESMAN_INI" "$TARGET_SESMAN_INI"
echo "[XRDP] sesman.ini 已更新，Xorg 后端已启用"

# 配置 xrdp.ini 的 session 类型为 xorg
TARGET_XRDP_INI="/etc/xrdp/xrdp.ini"
SRC_XRDP_INI="${SCRIPT_DIR}/resource/xrdp.ini"
if [[ -f "$TARGET_XRDP_INI" ]]; then
    cp "$TARGET_XRDP_INI" "${TARGET_XRDP_INI}.$$"
fi
cp "$SRC_XRDP_INI" "$TARGET_XRDP_INI"
echo "[XRDP] xrdp.ini session 类型已设为 xorg"

echo "[XRDP] 配置现有用户的 XRDP 会话..."
SESSION_CONTENT="xfce4-session"
list_login_users | while IFS=: read -r username user_home; do
    if [[ -d "$user_home" ]]; then
        # xorgxrdp 环境下使用 startxfce4 启动 XFCE 会话
        echo "startxfce4" > "$user_home/.xsession"
        chmod +x "$user_home/.xsession"
        chown "$username:$username" "$user_home/.xsession" 2>/dev/null || true
        ok "已配置 XRDP 会话: $username (使用 xorgxrdp 后端)"
    fi
done

# [Service]
echo "[XRDP] 启动 XRDP 服务..."
# 服务已启动/已启用时 start/enable 返回非零，属正常，用 || true 保证幂等
if [[ "$OS_VERSION" -eq 6 ]]; then
    chkconfig xrdp on || true
    chkconfig xrdp-sesman on || true

    /etc/init.d/xrdp restart || true
    /etc/init.d/xrdp-sesman restart || true
else
    systemctl enable xrdp || true
    systemctl enable xrdp-sesman || true

    systemctl restart xrdp xrdp-sesman || true
fi

echo "[XRDP] xrdp + xorgxrdp 配置完成！"

