#!/bin/bash
###############################################################################
# common.sh — 共享函数库
# 供所有子目录脚本 source 使用，统一输出风格与通用工具函数。
#
# 引用方式（子目录脚本顶部）:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../lib/common.sh"
#
# 根目录脚本引用方式:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# 提供函数:
#   --- 输出（带颜色，非终端自动禁用）---
#   ok    MSG   成功信息（stdout，绿色）
#   warn  MSG   警告信息（stdout，黄色）
#   error MSG   错误信息（stderr，红色）
#   die   MSG   错误信息（stderr）并 exit 1
#   --- 用户枚举 ---
#   list_login_users  输出可登录用户列表（username:home）
###############################################################################

# ---------- 颜色定义 ----------
# 仅当 stdout 为终端时启用颜色，避免重定向到文件时转义码污染日志
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi

# ---------- 输出函数 ----------
info()  { echo -e "${BLUE}ℹ️  $*${NC}"; }
ok()    { echo -e "${GREEN}✅ $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $*${NC}"; }
error() { echo -e "${RED}❌ $*${NC}" >&2; }
die()   { error "$*"; exit 1; }

# ---------- 枚举可登录用户 ----------
# 输出: username:home 每行一个，供 vnc/xrdp 配置脚本消费
# 过滤规则:
#   1. UID >= UID_MIN（动态读取 /etc/login.defs，读不到则按系统版本兜底:
#      RHEL/CentOS 6 → 500，7+ → 1000）
#   2. root 始终包含（与历史行为保持一致）
#   3. shell 非登录阻断类型（nologin/false/sync/shutdown/halt）
#   4. 拥有独立家目录（非空、非 /）
#   5. 排除 nobody（防御性，其 UID 在部分系统为 65534 会越过 UID_MIN）
list_login_users() {
    local uid_min os_ver
    uid_min=$(awk '$1=="UID_MIN"{print $2}' /etc/login.defs 2>/dev/null)
    if [[ -z "$uid_min" ]]; then
        os_ver=$(rpm -E %{rhel} 2>/dev/null || echo 7)
        if [[ "$os_ver" -eq 6 ]]; then
            uid_min=500
        else
            uid_min=1000
        fi
    fi

    awk -F: -v min="$uid_min" '
        ($3 >= min || $1 == "root") &&
        $1 != "nobody" &&
        $6 != "" && $6 != "/" &&
        $7 !~ /(nologin|false|sync|shutdown|halt)$/ \
        {print $1":"$6}
    ' /etc/passwd
}
