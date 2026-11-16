#!/bin/bash
# ================= app/rustfs/blkio.sh =================
# rustfs 块设备 I/O 限速：设备探测、测速、上限确认与 compose 渲染。
# 由 install.sh 在加载 script/common.sh 之后 source。

# 建议值折算百分比；静态默认值在测速不可用时直接使用
BLKIO_SUGGEST_PERCENT=80

# 测速不可用时的静态保守值（MiB/s、IOPS）
BLKIO_STATIC_READ_MIB=250
BLKIO_STATIC_WRITE_MIB=120
BLKIO_STATIC_READ_IOPS=400
BLKIO_STATIC_WRITE_IOPS=80

BLKIO_DEVICE=""
BLKIO_PROBE_FILE=""
BLKIO_PEAK_IS_STATIC=0
BLKIO_PEAK_READ_MIB=0
BLKIO_PEAK_WRITE_MIB=0
BLKIO_PEAK_READ_IOPS=0
BLKIO_PEAK_WRITE_IOPS=0
BLKIO_READ_LIMIT_MIB=0
BLKIO_WRITE_LIMIT_MIB=0
BLKIO_READ_LIMIT_IOPS=0
BLKIO_WRITE_LIMIT_IOPS=0

# 删除探测临时文件；可重复调用
blkio_cleanup() {
    if [ -n "$BLKIO_PROBE_FILE" ] && [ -f "$BLKIO_PROBE_FILE" ]; then
        rm -f "$BLKIO_PROBE_FILE"
    fi
}

# 从 findmnt 的 SOURCE 中去掉子卷后缀：/dev/sda1[/@] -> /dev/sda1
blkio_strip_subvol() {
    printf '%s\n' "${1%%\[*}"
}

# 正整数字符串校验
blkio_is_pos_int() {
    case "$1" in
        ''|*[!0-9]*|0[0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 9 ] || return 1
    [ "$1" -gt 0 ]
}

# value × percent / 100，向下取整，最小 1
blkio_scale() {
    local result
    blkio_is_pos_int "$1" || return 1
    blkio_is_pos_int "$2" || return 1
    result=$(( $1 * $2 / 100 ))
    [ "$result" -lt 1 ] && result=1
    printf '%s\n' "$result"
}

# MiB/s 数值渲染成 compose 的 rate 字符串
blkio_format_bps() {
    printf '%smib\n' "$1"
}
