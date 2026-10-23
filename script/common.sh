#!/bin/sh
# ================= script/common.sh =================

# 定义全局共享网络名称
TRAEFIK_NETWORK="web"

# 本库位于 <项目根>/script/ 下，据此定位运行时配置文件
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"
INSTALLER_CONF="${PROJECT_ROOT}/.installer.conf"

# 交互式读取封装：EOF（输入耗尽/Ctrl+D）时立即失败返回
ask() {
    local __var="$1" __prompt="${2:-}"
    [ -n "$__prompt" ] && printf '%s' "$__prompt"
    if ! IFS= read -r "$__var"; then
        printf '\n❌ 输入已结束（EOF），已中止。\n' >&2
        return 1
    fi
}

# 读取必填输入，结果写入指定变量
read_required() {
    local prompt="$1" var_name="$2" value
    while true; do
        printf "%s" "$prompt" >&2
        read -r value || { printf "\n❌ 输入已结束，已中止。\n" >&2; return 1; }
        [ -n "$value" ] && break
        printf "❌ 该项不能为空，请重新输入。\n" >&2
    done
    printf -v "$var_name" '%s' "$value"
}

# 读取带默认值的输入（回车使用默认值），结果写入指定变量
read_default() {
    local prompt="$1" default="$2" var_name="$3" value
    while true; do
        printf "%s [%s]: " "$prompt" "$default"
        read -r value || { printf "\n❌ 输入已结束，已中止。\n" >&2; return 1; }
        value="${value:-$default}"
        [ -n "$value" ] && break
        printf "❌ 该项不能为空，请重新输入。\n" >&2
    done
    printf -v "$var_name" '%s' "$value"
}

# 读取敏感输入（不回显），结果写入指定变量
read_secret() {
    local prompt="$1" var_name="$2" value
    while true; do
        printf "%s" "$prompt" >&2
        stty -echo
        read -r value || { stty echo; printf "\n❌ 输入已结束，已中止。\n" >&2; return 1; }
        stty echo
        printf "\n" >&2
        [ -n "$value" ] && break
        printf "❌ 该项不能为空，请重新输入。\n" >&2
    done
    printf -v "$var_name" '%s' "$value"
}

# 单选：当前来源/目标均只有一个选项，保留选择步骤便于后续扩展
choose_option() {
    local title="$1" option="$2" var_name="$3" choice
    while true; do
        printf "%s\n  1) %s\n" "$title" "$option" >&2
        printf "请输入序号 [1]: " >&2
        read -r choice || { printf "\n❌ 输入已结束，已中止。\n" >&2; return 1; }
        choice="${choice:-1}"
        [ "$choice" = "1" ] && break
        printf "❌ 无效选择 '%s'。\n" "$choice" >&2
    done
    printf -v "$var_name" '%s' "$option"
}

# 加载运行时配置（服务根目录、根域名等）
load_installer_conf() {
    [ -f "$INSTALLER_CONF" ] || return 0
    . "$INSTALLER_CONF"
}

# 向 .installer.conf 更新单个键值（不存在则追加，存在则替换，杜绝重复键）
set_installer_key() {
    local key="$1" value="$2" tmp="${INSTALLER_CONF}.tmp"
    {
        grep -v "^${key}=" "$INSTALLER_CONF" 2>/dev/null || true
        printf '%s="%s"\n' "$key" "$value"
    } > "$tmp" || { printf "❌ 无法写入 %s\n" "$INSTALLER_CONF"; return 1; }
    mv "$tmp" "$INSTALLER_CONF" || return 1
}

# 0. 解析服务根目录：首次运行交互确认并写入 .installer.conf，后续自动复用
resolve_service_base() {
    # 已有记录则直接复用，不再询问
    if [ -n "$SERVICE_BASE" ]; then
        printf "✅ 使用已记录的服务根目录: %s\n" "$SERVICE_BASE"
        return 0
    fi

    # 首次运行：交互输入，默认当前 home 下的 service 目录
    default_base="${HOME:-/root}/service"
    while true; do
        printf "请输入服务根目录 [%s]: " "$default_base"
        read -r input_base || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        input_base=${input_base:-$default_base}

        case "$input_base" in
            /*) break ;;
            *)  printf "❌ 服务根目录必须是以 / 开头的绝对路径，请重新输入。\n" ;;
        esac
    done

    # 提前验证可创建，避免装完才发现权限问题
    if ! mkdir -p "$input_base" 2>/dev/null; then
        printf "❌ 无法创建服务根目录 '%s'，请检查权限后重试。\n" "$input_base"
        return 1
    fi

    set_installer_key SERVICE_BASE "$input_base" || return 1
    SERVICE_BASE="$input_base"
    printf "✅ 服务根目录已记录到 %s，后续运行将自动复用。\n" "$INSTALLER_CONF"
    return 0
}

# 校验根域名格式（非空、无空格引号 $ * 等）
validate_root_domain() {
    case "$1" in
        ''|*[\"\'\ \`\$\*]*)
            printf "❌ 域名不能为空，且不能包含空格、引号、反引号、\$ 与 *。\n" >&2
            return 1 ;;
    esac
    return 0
}

# 0.1 解析泛域名证书根域名：已记录则复用，否则交互输入并持久化
resolve_root_domain() {
    if [ -n "$ROOT_DOMAIN" ]; then
        printf "✅ 使用已记录的根域名: %s\n" "$ROOT_DOMAIN"
        return 0
    fi

    local default_root="example.internal"
    while true; do
        printf "请输入泛域名证书根域名 [%s]: " "$default_root"
        read -r input_root || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        input_root=${input_root:-$default_root}
        validate_root_domain "$input_root" || continue
        case "$input_root" in
            .*|*.|*..*) printf "❌ 根域名格式无效，请重新输入。\n" >&2; continue ;;
        esac
        set_installer_key ROOT_DOMAIN "$input_root" || return 1
        ROOT_DOMAIN="$input_root"
        printf "✅ 根域名已记录到 %s，后续应用安装将自动复用。\n" "$INSTALLER_CONF"
        return 0
    done
}

# 代理模式应用需要根域名；缺失时提示先安装 traefik
require_root_domain() {
    if [ -z "$ROOT_DOMAIN" ]; then
        printf "❌ 未找到根域名配置（%s 中无 ROOT_DOMAIN）。\n" "$INSTALLER_CONF"
        printf "   反向代理模式需要先安装 traefik：bash run.sh install traefik\n"
        return 1
    fi
    return 0
}

# 校验应用域名是否被泛域名证书 *.ROOT_DOMAIN 覆盖
ensure_domain_covered() {
    local host="$1"
    case "$host" in
        "$ROOT_DOMAIN"|*."$ROOT_DOMAIN") return 0 ;;
        *)
            printf "❌ 域名 '%s' 不在泛域名证书 *.%s 的覆盖范围内。\n" "$host" "$ROOT_DOMAIN" >&2
            return 1 ;;
    esac
}

# 1. 加载公共库的快捷函数
load_common() {
    # 使用标准的 $0 获取脚本路径
    SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

    # 自动获取上级目录名作为默认安装名
    INSTALL_NAME=$(basename "$(cd "$SCRIPT_DIR" && pwd)")

    # 读取运行时配置（SERVICE_BASE / ROOT_DOMAIN）
    load_installer_conf

    # 确定服务根目录（首次交互指定，之后从配置文件复用）
    resolve_service_base || return 1

    # 在加载公共库时，自动调用网络初始化函数
    init_docker_network || return 1
}


# 1. 初始化 Docker 全局网络的函数
init_docker_network() {
    # 使用 docker network inspect 检查网络是否存在
    if ! docker network inspect "$TRAEFIK_NETWORK" >/dev/null 2>&1; then
        printf "⚠️  未检测到 Docker 网络 '%s'，正在自动创建...\n" "$TRAEFIK_NETWORK"
        docker network create "$TRAEFIK_NETWORK" >/dev/null 2>&1

        # 检查创建命令是否执行成功
        if [ $? -eq 0 ]; then
            printf "✅ 网络 '%s' 创建成功！\n" "$TRAEFIK_NETWORK"
        else
            printf "❌ 网络 '%s' 创建失败，请检查 Docker 服务状态！\n" "$TRAEFIK_NETWORK"
            return 1
        fi
    else
        printf "✅ 检测到 Docker 网络 '%s' 已存在。\n" "$TRAEFIK_NETWORK"
    fi
    return 0
}

# 1.5 放行防火墙端口：按存在的工具自动适配
#     ufw（Debian/Ubuntu）/ firewall-cmd（RHEL/Rocky/Fedora 的 firewalld）
#     两者都无则跳过并提示（可能无防火墙，或安全组在云平台层需自行放行）
open_firewall_ports() {
    local port fw_args=""
    if command -v ufw >/dev/null 2>&1; then
        for port in "$@"; do
            ufw allow "$port" || printf "⚠️  ufw 放行 '%s' 失败，请手动处理。\n" "$port"
        done
    elif command -v firewall-cmd >/dev/null 2>&1; then
        # firewalld 未运行时，主机层本就不拦流量，直接跳过
        if ! firewall-cmd --state >/dev/null 2>&1; then
            printf "ℹ️  firewalld 服务未运行，无主机防火墙拦截，跳过端口放行（云主机请确认安全组）。\n"
            return 0
        fi

        for port in "$@"; do
            fw_args="$fw_args --add-port=$port"
        done
        # shellcheck disable=SC2086  # fw_args 为固定的 --add-port= 参数序列，需按空格拆分
        firewall-cmd --permanent $fw_args && firewall-cmd --reload ||
            printf "⚠️  firewalld 放行 '%s' 失败，请手动处理。\n" "$*"
    else
        printf "⚠️  未检测到 ufw/firewalld，跳过防火墙配置；若有其他防火墙或云平台安全组，请自行放行 %s。\n" "$*"
    fi
}

# 2. 初始化服务目录的函数（支持用户确认或自定义服务名）
init_service() {
    current_name="$INSTALL_NAME"

    while true; do
        current_dir="${SERVICE_BASE}/${current_name}"

        printf "==========================================\n"
        printf "🔧 准备初始化服务: %s\n" "$current_name"
        printf "📂 目标服务目录: %s\n" "$current_dir"
        printf "==========================================\n"

        # 提示用户确认
        printf "请确认以上服务目录是否正确？(y/n) [y]: "
        read -r confirm || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        confirm=${confirm:-y}  # 默认值为 y

        # 判断用户输入
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            # 1. 用户确认，导出最终变量并跳出循环
            SERVICE_NAME="$current_name"
            SERVICE_DIR="$current_dir"
            export SERVICE_NAME SERVICE_DIR
            break

        elif [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
            # 2. 用户拒绝，提示输入自定义服务名
            printf "请输入自定义的服务名称: "
            read -r custom_name || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }

            # 防止用户直接回车输入空值
            if [ -n "$custom_name" ]; then
                current_name="$custom_name"
                printf "\n⚠️  已切换服务名为: %s\n\n" "$current_name"
            else
                printf "\n⚠️  输入不能为空，请重新确认。\n\n"
            fi

        else
            # 3. 输入了其他无效字符，提示错误并重新循环
            printf "\n❌ 无效输入 '%s'，请输入 y 或 n。\n\n" "$confirm"
        fi
    done

    # 4. 核心防御检查：如果目标目录已经存在，则报错并中断
    if [ -d "$SERVICE_DIR" ]; then
        printf "❌ 致命错误: 目标目录 '%s' 已经存在！\n" "$SERVICE_DIR"
        printf "请删除该目录或更换服务名称后重试。\n"
        return 1
    fi

    # 5. 检查通过，执行创建目录操作
    mkdir -p "$SERVICE_DIR" || { printf "❌ 目录创建失败，请检查权限！\n"; return 1; }

    # 将应用自带的维护脚本复制到服务目录：脚本通过自身所在目录定位服务目录，
    # 安装后可直接运行 $SERVICE_DIR/configure.sh，无需依赖源码目录。
    if [ -f "$SCRIPT_DIR/configure.sh" ]; then
        cp "$SCRIPT_DIR/configure.sh" "$SERVICE_DIR/configure.sh" || {
            printf "❌ 维护脚本复制失败: %s/configure.sh\n" "$SERVICE_DIR"
            return 1
        }
        chmod +x "$SERVICE_DIR/configure.sh"
        printf "✅ 已安装维护脚本: %s/configure.sh\n" "$SERVICE_DIR"
    fi

    printf "✅ 服务目录准备就绪: %s\n" "$SERVICE_DIR"
    return 0
}

# 3. 转义 sed 替换内容中的特殊字符（\ & 以及分隔符 |）
# 用法: sed -i "s|__PLACEHOLDER__|$(sed_escape "$VALUE")|g" 文件
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# 3.4 部署方式：默认反向代理（Traefik + 域名 + 证书），
#     也可直接发布宿主机端口、不依赖 Traefik
# 结果: INSTALL_MODE=proxy|direct
choose_install_mode() {
    local choice
    printf "==========================================\n"
    printf "🔀 请选择部署方式\n"
    printf "==========================================\n"
    printf "  1) 反向代理（Traefik + 域名 + 证书）[默认]\n"
    printf "  2) 直接访问（发布宿主机端口，不使用 Traefik）\n"
    printf "请输入序号 (1/2) [1]: "
    read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
    case "${choice:-1}" in
        1) INSTALL_MODE="proxy" ;;
        2) INSTALL_MODE="direct" ;;
        *) printf "❌ 无效输入 '%s'，请输入 1 或 2。\n" "$choice"; return 1 ;;
    esac
    return 0
}

# 交互读取直接访问模式的宿主机端口（回车使用默认值）
# 参数: $1=提示文案 $2=默认端口；结果: DIRECT_PORT
ask_host_port() {
    local label="$1" default="$2" p
    while true; do
        printf "请输入%s [%s]: " "$label" "$default"
        read -r p || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        p="${p:-$default}"
        case "$p" in
            ''|*[!0-9]*) printf "❌ 端口须为数字，请重新输入。\n"; continue ;;
        esac
        [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { printf "❌ 端口须在 1-65535。\n"; continue; }
        DIRECT_PORT="$p"
        return 0
    done
}

# 交互读取直接访问使用的主机地址（IP 或域名），供需要绝对 URL 的应用使用
# 结果: DIRECT_HOST
ask_direct_host() {
    local default_host
    default_host=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$default_host" ] || default_host="127.0.0.1"

    while true; do
        printf "请输入直接访问使用的主机地址（IP 或域名）[%s]: " "$default_host"
        read -r DIRECT_HOST || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        DIRECT_HOST=${DIRECT_HOST:-$default_host}
        case "$DIRECT_HOST" in
            ''|*[[:space:]]*) printf "❌ 主机地址不能为空，且不能包含空格。\n"; continue ;;
        esac
        return 0
    done
}