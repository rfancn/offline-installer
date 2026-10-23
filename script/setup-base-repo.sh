#!/bin/bash
# === 通用本地 ISO 仓库配置脚本 (支持 YUM & APT) ===
set -e

# 1. 检查参数
if [ -z "$1" ]; then
    echo " 错误: 请提供 ISO 镜像文件的路径作为参数。"
    echo "用法: sudo bash $0 /path/to/os-image.iso"
    exit 1
fi

ISO_PATH="$1"
MOUNT_POINT="/mnt/iso"

# 2. 检查 ISO 文件是否存在
if [ ! -f "$ISO_PATH" ]; then
    echo " 错误: 找不到指定的 ISO 文件: $ISO_PATH"
    exit 1
fi

# 3. 检测操作系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
else
    echo " 错误: 无法识别操作系统 (缺少 /etc/os-release)。"
    exit 1
fi

echo "[1/5] 创建挂载点并挂载 ISO..."
sudo mkdir -p "$MOUNT_POINT"
sudo umount "$MOUNT_POINT" 2>/dev/null || true
sudo mount -o loop "$ISO_PATH" "$MOUNT_POINT"
echo " ISO 挂载成功: $MOUNT_POINT"

# 4. 根据系统类型配置本地源
if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    echo "[2/5] 检测到 Debian/Ubuntu 系统，配置 APT 源..."
    
    # 获取 Ubuntu 版本代号
    if [ -z "$VERSION_CODENAME" ]; then
        echo " 错误: 无法获取系统版本代号 (VERSION_CODENAME)。"
        exit 1
    fi
    
    SOURCE_FILE="/etc/apt/sources.list.d/local-iso.sources"
    sudo tee "$SOURCE_FILE" > /dev/null <<EOF
Types: deb
URIs: file://$MOUNT_POINT
Suites: $VERSION_CODENAME
Components: main restricted universe multiverse
Enabled: yes
Options: trusted=yes
EOF
    echo " APT 源配置完成: $SOURCE_FILE"
    
    echo "[3/5] 更新 APT 缓存..."
    sudo apt update
    echo " 成功! APT 本地 ISO 源已生效。"

elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "openEuler" || "$OS_ID" == "fedora" ]]; then
    echo "[2/5] 检测到 RHEL/CentOS 系统，配置 YUM 源..."
    
    REPO_FILE="/etc/yum.repos.d/local-base.repo"
    sudo tee "$REPO_FILE" > /dev/null <<EOF
[local-iso]
name=Local ISO Repository
baseurl=file://$MOUNT_POINT
enabled=1
gpgcheck=0
EOF
    echo " YUM 源配置完成: $REPO_FILE"
    
    echo "[3/5] 清理并重建 YUM 缓存..."
    sudo yum clean all
    sudo yum makecache
    echo " 成功! YUM 本地 ISO 源已生效。"

else
    echo " 错误: 当前系统 ($OS_ID) 暂不支持此脚本的自动配置。"
    exit 1
fi

# 5. 验证配置
echo "[4/5] 验证本地源..."
if command -v apt-cache &> /dev/null && apt-cache policy | grep -q "file:$MOUNT_POINT"; then
    echo " 验证通过: APT 本地源已正确加载。"
elif command -v yum &> /dev/null && yum repolist enabled | grep -q "local-iso"; then
    echo " 验证通过: YUM 本地源已正确加载。"
else
    echo "️ 警告: 本地源似乎未生效，请手动检查配置文件。"
fi

echo "[5/5] 配置完成！"
