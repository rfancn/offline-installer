#!/usr/bin/env bash
# Go 安装脚本
# 从 assets/golang 目录解压 Go 安装包到 /usr/local/go，并配置 PATH 环境变量。

set -euo pipefail

# 脚本所在目录（保证无论从哪个路径执行都能找到 resource）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Go 安装包文件名（位于 assets/golang 目录下）
GO_ARCHIVE="${SCRIPT_DIR}/../../assets/golang/go1.27.1.linux-amd64.tar.gz"

# 若非 root 用户，提取到 /usr/local 需要 sudo 提权
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
fi

# 1. 校验安装包是否存在
if [[ ! -f "${GO_ARCHIVE}" ]]; then
  echo "错误：未找到 Go 安装包 ${GO_ARCHIVE}" >&2
  exit 1
fi

# 2. 删除旧版本并解压到 /usr/local（不要直接解压到已存在的 /usr/local/go）
echo "正在安装 Go ..."
${SUDO} rm -rf /usr/local/go
${SUDO} tar -C /usr/local -xzf "${GO_ARCHIVE}"

# 3. 配置 PATH
GO_BIN_LINE='export PATH=$PATH:/usr/local/go/bin'
GO_BIN_PATH='/usr/local/go/bin'

# 3.2 $HOME/go/bin（go install 默认目录）-> ~/.bash_profile
if ! grep -qF '$GO_BIN_PATH' "${HOME}/.bash_profile" 2>/dev/null; then
  echo "${GO_BIN_LINE}" >> "${HOME}/.bash_profile"
fi

# 4. 立即生效（无需重新登录）
export PATH="$PATH:$GO_BIN_PATH"

# 5. 验证安装
echo "Go 安装完成，版本信息如下："
go version
