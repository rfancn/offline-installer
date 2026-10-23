#!/bin/bash
# run.sh — 安全策略配置（SELinux/防火墙）
set -euo pipefail

# ---------- 加载共享函数库 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

OS_VERSION=$(rpm -E %{rhel})
echo "==================== [Security] ===================="

# [Configure]
#echo "[Security] 1/2 配置防火墙放行端口..."
#if [[ "$OS_VERSION" -eq 6 ]]; then
#    iptables -I INPUT -p tcp --dport 3389 -j ACCEPT
#    iptables -I INPUT -p tcp --dport 5901 -j ACCEPT
#    service iptables save
#else
#    firewall-cmd --permanent --add-port=3389/tcp || true
#    firewall-cmd --permanent --add-port=5901/tcp || true
#    firewall-cmd --reload || true
#fi

# [Service]
echo "[Security] 调整 SELinux 策略..."
setenforce 0 || true
sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config || true
