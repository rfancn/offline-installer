#!/bin/bash
# run.sh — 安装并配置 XFCE 桌面环境
set -euo pipefail

# ---------- 加载共享函数库 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

OS_VERSION=$(rpm -E %{rhel})
echo "==================== [XFCE] ===================="

# [Install]
echo "[XFCE] 安装 XFCE 桌面环境..."
# groupinstall 对已装组返回非零，用 || 兜底；组名在不同版本有差异，依次尝试
yum groupinstall -y "Xfce" || yum groupinstall -y "Xfce Desktop" || true
yum install -y xfce* xfwm4 xfdesktop thunar lightdm

# [Configure]
echo "[XFCE] 配置全局 XFCE 会话..."
SESSION_CONTENT="xfce4-session"
mkdir -p /etc/skel
echo "$SESSION_CONTENT" > /etc/skel/.xsession && chmod +x /etc/skel/.xsession
echo "$SESSION_CONTENT" > /etc/skel/.Xclients && chmod +x /etc/skel/.Xclients

cat > /etc/X11/xinit/Xclients <<'EOF'
#!/bin/bash
exec /usr/bin/xfce4-session
EOF
chmod +x /etc/X11/xinit/Xclients

# [Service]
echo "[XFCE] 启用 LightDM 显示管理器..."
# systemctl enable 对已启用的服务返回非零，属正常
if [[ "$OS_VERSION" -eq 6 ]]; then
    chkconfig gdm off || true
    chkconfig lightdm on || true
else
    systemctl disable gdm.service || true
    systemctl enable lightdm.service || true
    systemctl set-default graphical.target || true
fi
