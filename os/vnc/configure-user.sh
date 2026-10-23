#!/bin/bash
###############################################################################
# configure-user.sh — VNC 用户配置脚本
# 用法: sudo ./configure-user.sh <username>
# 说明:
#   - 所有参数从 /etc/vnc-users 读取或自动分配
#   - 用户已存在 → 使用已有配置
#   - 用户不存在 → 自动分配下一个可用显示号，追加完整记录
#   - /etc/vnc-users 缺失 → 报错并提示运行 vnc/run.sh
###############################################################################
set -euo pipefail

# ---------- 加载共享函数库 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

VNC_USERS_FILE="/etc/vnc-users"
DEFAULT_GEOMETRY="2560x1440"
DEFAULT_DEPTH="24"

# ---------- 参数校验 ----------
TARGET_USER="${1:-}"
if [[ -z "$TARGET_USER" ]]; then
    echo "用法: sudo $0 <username>" >&2
    exit 1
fi

if ! id "$TARGET_USER" &>/dev/null; then
    die "用户 '$TARGET_USER' 不存在"
fi

# ---------- 检查 /etc/vnc-users 是否存在 ----------
if [[ ! -f "$VNC_USERS_FILE" ]]; then
    die "配置文件 $VNC_USERS_FILE 不存在，请先运行: sudo vnc/run.sh"
fi

# ---------- 从 /etc/vnc-users 读取或自动分配 ----------
USER_LINE=$(grep "^${TARGET_USER}:" "$VNC_USERS_FILE" | head -1 || true)

if [[ -n "$USER_LINE" ]]; then
    # 用户已存在 → 使用已有配置
    DISPLAY_NUM=$(echo "$USER_LINE" | cut -d: -f2)
    GEOMETRY=$(echo "$USER_LINE" | cut -d: -f3)
    DEPTH=$(echo "$USER_LINE" | cut -d: -f4)
    ok "用户 '$TARGET_USER' 已存在，使用现有配置"
else
    # 用户不存在 → 自动分配下一个可用显示号
    MAX_DISPLAY=0
    while IFS=: read -r _user disp _rest; do
        # 跳过空行和注释行（以 # 开头，允许前导空白）
        [[ -z "$_user" ]] && continue
        [[ "$_user" =~ ^[[:space:]]*# ]] && continue
        if [[ "$disp" =~ ^[0-9]+$ ]] && [[ "$disp" -gt "$MAX_DISPLAY" ]]; then
            MAX_DISPLAY="$disp"
        fi
    done < "$VNC_USERS_FILE"

    DISPLAY_NUM=$((MAX_DISPLAY + 1))
    GEOMETRY="$DEFAULT_GEOMETRY"
    DEPTH="$DEFAULT_DEPTH"

    NEW_RECORD="${TARGET_USER}:${DISPLAY_NUM}:${GEOMETRY}:${DEPTH}"
    echo "$NEW_RECORD" >> "$VNC_USERS_FILE"
    ok "已为用户 '$TARGET_USER' 分配显示号 :$DISPLAY_NUM 并追加到 $VNC_USERS_FILE"
fi

# ---------- 校验分配结果 ----------
if ! [[ "$DISPLAY_NUM" =~ ^[0-9]+$ ]]; then
    die "无效的显示号: '$DISPLAY_NUM'"
fi

if ! [[ "$DEPTH" =~ ^(8|16|24|32)$ ]]; then
    die "无效的颜色深度: '$DEPTH'（支持 8/16/24/32）"
fi

HOMEDIR=$(eval echo "~$TARGET_USER")

# ---------- 1. ~/.vnc/config（仅写入 Xvnc 合法选项，不含 DISPLAY_NUM）----------
mkdir -p "$HOMEDIR/.vnc"

cat > "$HOMEDIR/.vnc/config" <<EOF
GEOMETRY=${GEOMETRY}
DEPTH=${DEPTH}
EOF

chown "$TARGET_USER:$TARGET_USER" "$HOMEDIR/.vnc/config"
chmod 600 "$HOMEDIR/.vnc/config"

# ---------- 2. ~/.vnc/xstartup ----------
cat > "$HOMEDIR/.vnc/xstartup" <<'XSTARTUP'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11

# 启动桌面环境（按优先级尝试）
if command -v startxfce4 >/dev/null 2>&1; then
    exec startxfce4
elif command -v mate-session >/dev/null 2>&1; then
    exec mate-session
elif command -v gnome-session >/dev/null 2>&1; then
    exec gnome-session
elif [ -x /etc/X11/xinit/xinitrc ]; then
    exec sh /etc/X11/xinit/xinitrc
else
    echo "❌ 未找到可用的桌面环境" >&2
    exit 1
fi
XSTARTUP

chown "$TARGET_USER:$TARGET_USER" "$HOMEDIR/.vnc/xstartup"
chmod 755 "$HOMEDIR/.vnc/xstartup"

# ---------- 3. 确保 ~/.vnc 目录权限正确 ----------
chown "$TARGET_USER:$TARGET_USER" "$HOMEDIR/.vnc"
chmod 700 "$HOMEDIR/.vnc"

echo "以 $TARGET_USER 身份执行 'vnc start' 启动 VNC"
