#!/bin/bash
set -euo pipefail

# ============================================================
# 挂载指定 ISO 并配置本地 EPEL 仓库
# 用法: bash install.sh <iso_image_path>
# 挂载点固定: /mnt/epel
# ============================================================

MNT="/mnt/epel"
REPO="/etc/yum.repos.d/local-epel.repo"
SRC="${MNT}/Packages"

# ---------- 参数校验 ----------
if [[ $# -ne 1 ]]; then
    echo "用法: bash install.sh <iso_image_path>"
    echo "示例: bash install.sh /opt/centos7.9-epel.iso"
    exit 1
fi

ISO_PATH="$(realpath "$1")"
[[ -f "${ISO_PATH}" ]] || { echo "❌ ISO 文件不存在: ${ISO_PATH}"; exit 1; }

# ---------- [1/4] 创建挂载点并挂载 ----------
echo "===== [1/4] 挂载 ISO ====="
mkdir -p "${MNT}"

# 如果已挂载其他设备，先卸载
if mountpoint -q "${MNT}" 2>/dev/null; then
    echo "  ⚠️  ${MNT} 已被占用，尝试卸载..."
    umount "${MNT}" || { echo "❌ 卸载失败，请手动处理: umount ${MNT}"; exit 1; }
fi

mount -o loop,ro "${ISO_PATH}" "${MNT}"
echo "  ✅ ${ISO_PATH} -> ${MNT}"

# ---------- [2/4] 校验内容 ----------
echo "===== [2/4] 校验 ISO 内容 ====="
[[ -d "${SRC}" ]] || { echo "❌ ${SRC} 不存在，ISO 结构不正确"; umount "${MNT}"; exit 1; }
CNT=$(find "${MNT}" -maxdepth 3 -name '*.rpm' | wc -l)
echo find "${MNT}" -maxdepth 3 -name '*.rpm' | wc -l
(( CNT > 0 )) || { echo "❌ 未找到 RPM 包"; umount "${MNT}"; exit 1; }
echo "  ✅ ${CNT} 个 RPM 包就绪"

# ---------- [3/4] 写入 repo 文件 ----------
echo "===== [3/4] 配置 YUM 仓库 ====="
for f in /etc/yum.repos.d/epel*.repo; do
    [[ -f "$f" ]] && sed -i 's/^enabled=1/enabled=0/' "$f"
done

cat > "${REPO}" <<EOF
[local-epel]
name=CentOS 7.9 Local EPEL (ISO)
baseurl=file://${MNT}
enabled=1
gpgcheck=0
cost=1
EOF

# ---------- [4/4] 刷新缓存并验证 ----------
echo "===== [4/4] 刷新缓存并验证 ====="
yum clean all &>/dev/null
yum makecache fast &>/dev/null

if yum repolist enabled 2>/dev/null | grep -q local-epel; then
    echo ""
    echo "========================================="
    echo " ✅ 本地 EPEL 仓库已就绪"
    echo "========================================="
    echo " ISO:    ${ISO_PATH}"
    echo " 挂载点: ${MNT} (只读)"
    echo " baseurl: file://${SRC}"
    echo " RPM数:  ${CNT}"
    echo ""
    echo " 测试: yum list available xrdp"
    echo ""
    echo " ⚠️  重启后需重新挂载或写入 fstab:"
    echo "   echo '${ISO_PATH} ${MNT} iso9660 loop,ro 0 0' >> /etc/fstab"
    echo "========================================="
else
    echo "❌ 仓库验证失败"
    umount "${MNT}"
    exit 1
fi
