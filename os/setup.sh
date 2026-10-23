#!/bin/bash
# setup.sh — RHEL/CentOS 桌面环境部署主入口（XFCE4 + XRDP + VNC）
set -euo pipefail

# ---------- 加载共享函数库 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# ---------- 0. 前置检查 ----------
if [[ $(id -u) -ne 0 ]]; then
    die "请使用 root 用户执行此脚本"
fi

OS_VERSION=$(rpm -E %{rhel})
info "========================================="
info " 检测到系统版本: RHEL/CentOS $OS_VERSION"
info " 开始部署 XFCE4 + XRDP + VNC 环境"
info "========================================="

# ---------- 1. 定义模块执行顺序 ----------
# 严格按照依赖关系排序：基础环境 -> 桌面 -> 远程桌面 -> 安全配置
MODULES=(
    "base"
    "xfce"
    "xrdp"
    "vnc"
    "security"
)

# ---------- 2. 依次调用子目录下的 run.sh ----------
for module in "${MODULES[@]}"; do
    SCRIPT_PATH="./${module}/run.sh"

    # 增加加载校验，避免因文件缺失导致脚本报错
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        warn "模块脚本不存在，已跳过 -> $SCRIPT_PATH"
        continue
    fi

    echo ""
    echo ">>> 正在执行模块: $module"
    bash "$SCRIPT_PATH"
done

# ---------- 3. 部署完成提示 ----------
info ""
info "========================================="
info " 所有模块部署完成！"
info " 下一步请重启系统: reboot"
info "========================================="
