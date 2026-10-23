#!/bin/bash
# run.sh — 安装 X Window 系统基础组件
set -euo pipefail

# ---------- 加载共享函数库 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

info "==================== [Base] ===================="

# [Install]
echo "[Base] 安装 X Window 系统基础组件..."
yum clean all && yum makecache
# yum install 天然幂等：已装的包会跳过
yum install -y xorg-x11-server-Xorg xorg-x11-fonts-Type1 xorg-x11-fonts-misc dbus-x11

# [Configure]
info "[Base] 配置系统 Locale 和中文字体..."
# 字体包在部分源中不存在，失败时跳过不中断
yum install -y google-noto-sans-cjk-fonts wqy-microhei-fonts || true
# localedef 对已存在的 locale 返回非零，属正常
localedef -i en_US -f UTF-8 en_US.UTF-8 || true
cat > /etc/locale.conf <<'EOF'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF
localectl set-locale LANG=en_US.UTF-8 || true

# [Service]
info "关闭无用的服务"
systemctl stop abrtd abrt-ccpp abrt-oops abrt-xorg
systemctl disable abrtd abrt-ccpp abrt-oops abrt-xorg
