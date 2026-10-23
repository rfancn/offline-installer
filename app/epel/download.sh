#!/bin/bash
set -euo pipefail

# ============================================================
# CentOS 7.9 EPEL 离线 ISO 生成器
# 输出: ./centos7.9-epel.iso
# 注意: install.sh 不嵌入 ISO，需单独传输到目标机器
# ============================================================

ISO_NAME="centos7.9-epel.iso"
#STAGE="/tmp/_epel_iso_stage_$$"
STAGE="/tmp/epel"

mkdir -p $STAGE

#cleanup() {
#    echo "===== 清理临时目录 ====="
#    rm -rf "${STAGE}"
#}
#trap cleanup EXIT

echo "===== [1/6] 安装依赖 ====="
yum install -y yum-utils createrepo genisoimage

echo "===== [2/6] 准备暂存目录 ====="
mkdir -p "${STAGE}"

#echo "===== [3/6] 同步 EPEL 7 RPM (仅最新版) ====="
#reposync --repoid=epel \
#         --download_path="${STAGE}" \
#         --norepopath \
#         --newest-only \
#         --gpgcheck

echo "===== [4/6] 同步 EPEL 7 RPM (仅最新版) ====="
# 在 YUM 缓存中查找 comps.xml 文件
COMPS_FILE=$(find /var/cache/yum -name "*comps*.xml" | grep epel | head -n 1)
if [[ -z "$COMPS_FILE" ]]; then
    echo "⚠️  警告: 未在缓存中找到 comps.xml，尝试刷新缓存后重试..."
    yum makecache
    COMPS_FILE=$(find /var/cache/yum -name "*comps*.xml" | grep epel | head -n 1)
fi

if [[ -n "$COMPS_FILE" ]]; then
    echo "  ✅找到组信息文件: $COMPS_FILE"
    cp "$COMPS_FILE" "${STAGE}/comps.xml"
else
    echo "❌ 错误: 无法找到 EPEL 的 comps.xml，groupinstall 将不可用！"
    exit 1
fi

# 3. 使用 -g 参数生成包含组信息的元数据
echo "===== [5/6] 正在生成包含组信息的元数据 ====="
createrepo -g "${STAGE}/comps.xml" "${STAGE}"


echo "===== [6/6] 生成 ISO ====="
genisoimage -R -J -V "CentOS7-EPEL" \
            -o "${ISO_NAME}" \
            -quiet "${STAGE}"

echo ""
echo "✅ 完成: $(pwd)/${ISO_NAME} ($(du -sh "${ISO_NAME}" | cut -f1))"
echo "   临时文件已自动清理"
echo ""
