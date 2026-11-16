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

# 从 fio JSON 取值：优先 jq，其次 python3，最后 awk
blkio_fio_value_jq() {
    local json="$1" dir="$2" metric="$3" value
    command -v jq >/dev/null 2>&1 || return 1
    value=$(jq -r --arg d "$dir" --arg m "$metric" '.jobs[0][$d][$m] // empty' "$json" 2>/dev/null) || return 1
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

blkio_fio_value_python() {
    local json="$1" dir="$2" metric="$3"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$json" "$dir" "$metric" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        job = json.load(handle)["jobs"][0]
    print(job[sys.argv[2]][sys.argv[3]])
except Exception:
    sys.exit(1)
PY
}

# 无 jq/python3 时的最小解析：依赖 fio 默认的缩进 JSON；
# 目标段必含请求的指标，因此 indir 置位后不在段间复位
blkio_fio_value_awk() {
    awk -v dir="\"$2\"" -v metric="\"$3\"" '
        index($0, "\"jobs\"") { injobs = 1 }
        injobs && index($0, dir) { indir = 1 }
        indir && match($0, metric "[ \t]*:[ \t]*[0-9.]+") {
            value = substr($0, RSTART, RLENGTH)
            sub(/^[^:]*:[ \t]*/, "", value)
            print value
            exit
        }
    ' "$1"
}

# 合法数值：整数或小数（不接受空、负号、多个小数点、首尾小数点）
blkio_is_number() {
    case "$1" in
        ''|*[!0-9.]*|*.*.*|.*|*.) return 1 ;;
    esac
    return 0
}

blkio_fio_value() {
    local json="$1" dir="$2" metric="$3" value
    value=$(blkio_fio_value_jq "$json" "$dir" "$metric") &&
        blkio_is_number "$value" && { printf '%s\n' "$value"; return 0; }
    value=$(blkio_fio_value_python "$json" "$dir" "$metric") &&
        blkio_is_number "$value" && { printf '%s\n' "$value"; return 0; }
    value=$(blkio_fio_value_awk "$json" "$dir" "$metric" 2>/dev/null) || return 1
    blkio_is_number "$value" || return 1
    printf '%s\n' "$value"
}
