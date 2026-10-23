#!/bin/bash

# 1. 引入公共库并自动计算服务名
# 使用标准的 $0 获取当前脚本的真实绝对路径
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
# 统一入口 run.sh 可能从任意目录调起，切换到脚本目录以保证 resource/ 相对路径有效
cd "$SCRIPT_PATH" || exit 1
COMMON_SCRIPT="${SCRIPT_PATH}/../../script/common.sh"

# 检查公共库是否存在
if [ ! -f "$COMMON_SCRIPT" ]; then
    printf "❌ 致命错误: 找不到公共库 %s\n" "$COMMON_SCRIPT"
    exit 1
fi

# 引入公共库
. "$COMMON_SCRIPT"
load_common || exit 1


# 2. 执行初始化（直接生成 $INSTALL_DIR 和 $SERVICE_NAME）
init_service || exit 1

echo "🚀 开始将服务安装到: $SERVICE_DIR"

# 收集泛域名证书根域名；已安装过则复用 .installer.conf 中的记录
resolve_root_domain || exit 1

# 安装certs
MKCERT="${SCRIPT_PATH}/../../assets/traefik/mkcert"
"${MKCERT}" -install
CAROOT=$("${MKCERT}" -CAROOT 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$CAROOT" ]; then
    echo "错误: 无法获取 mkcert 路径。请确认已安装 mkcert 并运行过 'mkcert -install'。"
    exit 1
fi

# 2. 检查根证书文件是否存在
if [ ! -f "${CAROOT}/rootCA.pem" ] || [ ! -f "${CAROOT}/rootCA-key.pem" ]; then
    echo "错误: 在 ${CAROOT} 下未找到 rootCA.pem 或 rootCA-key.pem。"
    echo "请运行 'mkcert -install' 初始化本地 CA。"
    exit 1
fi

echo "成功定位 CA 根目录: ${CAROOT}"

# ================= 配置区 ==================
DOMAIN="$ROOT_DOMAIN"        # 安装时收集的泛域名根域名
CERTS_DIR="$SERVICE_DIR/certs"   # 证书输出目录
VALIDITY_DAYS=36500          # 有效期：100年
# ==========================================
mkdir -p "${CERTS_DIR}"

# 4. 生成私钥
echo "正在生成私钥 server.key ..."
openssl genrsa -out "${CERTS_DIR}/server.key" 2048


# 5. 生成 CSR (证书签名请求)
echo "正在生成 CSR 请求..."
openssl req -new -key "${CERTS_DIR}/server.key" \
  -out "${CERTS_DIR}/server.csr" \
  -subj "/CN=*.${DOMAIN}" \
  -addext "subjectAltName=DNS:*.${DOMAIN},DNS:${DOMAIN}"

# 6. 使用 mkcert 的根证书签发泛域名证书
echo "正在使用本地 CA 签发有效期为 ${VALIDITY_DAYS} 天的证书..."
openssl x509 -req \
  -in "${CERTS_DIR}/server.csr" \
  -CA "${CAROOT}/rootCA.pem" \
  -CAkey "${CAROOT}/rootCA-key.pem" \
  -CAcreateserial \
  -out "${CERTS_DIR}/server.crt" \
  -days ${VALIDITY_DAYS} \
  -sha256 \
  -copy_extensions copyall

# 7. 清理临时文件并验证
rm -f "${CERTS_DIR}/server.csr" "${CAROOT}/rootCA.srl"

echo "----------------------------------------"
echo "证书生成成功！"
echo "证书路径: ${CERTS_DIR}/server.crt"
echo "私钥路径: ${CERTS_DIR}/server.key"
echo "有效期至: $(openssl x509 -in ${CERTS_DIR}/server.crt -noout -enddate)"
echo "----------------------------------------"

# 安装配置文件
CONFIG_DIR="${SERVICE_DIR}/config"
mkdir -p "${CONFIG_DIR}"
cp resource/config/* ${CONFIG_DIR}/

# 安装docker-compose.yml
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
cp resource/docker-compose.yml $COMPOSE_FILE

# 1. 检查 htpasswd 工具是否安装
if ! command -v htpasswd >/dev/null 2>&1; then
    printf "⚠️  未检测到 htpasswd 工具，正在尝试安装 apache2-utils...\n"
    sudo apt update && sudo apt install -y apache2-utils
fi

# 2. 提示用户输入用户名和密码
printf "==========================================\n"
printf "🔐 请配置 Traefik Dashboard 访问凭证\n"
printf "==========================================\n"
printf "请输入管理员用户名: "
read -r DASHBOARD_USER

printf "请输入管理员密码 (输入时不可见): "
stty -echo  # 隐藏密码输入
read -r DASHBOARD_PASS
stty echo   # 恢复显示
printf "\n"  # 换行，保持输出美观

# 3. 生成密码哈希
# -nB 表示在标准输出显示并使用 bcrypt 加密（Traefik 推荐）
HASH=$(htpasswd -nbB "$DASHBOARD_USER" "$DASHBOARD_PASS" | cut -d ":" -f 2)

# 4. 使用 sed 替换 dashboard.toml 中的占位符
#    Dashboard 域名为 traefik.<根域名>，由泛域名证书覆盖
DASHBOARD_DOMAIN="traefik.${DOMAIN}"
DASHBOARD_CONFIG_FILE="$CONFIG_DIR"/dashboard.toml
sed -i "s|__DASH_BOARD_DOMAIN__|$(sed_escape "$DASHBOARD_DOMAIN")|g" "$DASHBOARD_CONFIG_FILE"
sed -i "s|__DASH_BOARD_CREDENTIAL__|$(sed_escape "${DASHBOARD_USER}:${HASH}")|g" "$DASHBOARD_CONFIG_FILE"

printf "✅ Traefik Dashboard 认证配置已写入！\n"

# 5. 放行防火墙端口
open_firewall_ports 80/tcp 443/tcp

printf -- "----------------------------------------\n"
printf "泛域名证书: *.%s / %s\n" "$DOMAIN" "$DOMAIN"
printf "Dashboard:  https://%s/dashboard/\n" "$DASHBOARD_DOMAIN"
printf "⚠️  客户端需导入 mkcert 根证书: %s/rootCA.pem\n" "$CAROOT"
printf "⚠️  根域名记录在 %s；如需修改，编辑或删除该文件后重跑本脚本，\n" "$INSTALLER_CONF"
printf "   并重新安装已部署的应用以同步域名。\n"
printf -- "----------------------------------------\n"

echo "✅ $INSTALL_NAME 安装完成！"




