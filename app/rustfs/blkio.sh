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
BLKIO_PEAK_READ_IOPS_STATIC=0
BLKIO_PEAK_WRITE_IOPS_STATIC=0
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

# 取数据目录底层块设备；无法探测时返回 1
blkio_detect_device() {
    local src
    command -v findmnt >/dev/null 2>&1 || return 1
    src=$(findmnt -no SOURCE -T "$SERVICE_DIR/data" 2>/dev/null) || return 1
    [ -n "$src" ] || return 1
    blkio_strip_subvol "$src"
}

# 测试文件大小（MiB）：min(1 GiB, 可用空间/4)，不足 256 MiB 返回 1
blkio_probe_size_mib() {
    local avail_kb size_mib
    avail_kb=$(df -Pk "$SERVICE_DIR/data" 2>/dev/null | awk 'NR==2 {print $4}')
    case "$avail_kb" in
        ''|*[!0-9]*) return 1 ;;
    esac
    size_mib=$((avail_kb / 1024 / 4))
    [ "$size_mib" -gt 1024 ] && size_mib=1024
    [ "$size_mib" -lt 256 ] && return 1
    printf '%s\n' "$size_mib"
}

# 自 /proc/uptime 取厘秒数（顺序测速用）
blkio_now_cs() {
    awk '{ printf "%d\n", $1 * 100 }' /proc/uptime
}

# 纳秒时间戳；不支持 %N 时返回 1（随机 IOPS 用）
blkio_now_ns() {
    local ns
    ns=$(date +%s%N 2>/dev/null)
    case "$ns" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$ns"
}

# 运行一组 fio 测试并输出指标；失败返回 1
# 参数: 文件 JSON路径 rw bs iodepth read|write bw|iops
blkio_fio_run() {
    local file="$1" json="$2" rw="$3" bs="$4" depth="$5" dir="$6" metric="$7" size
    size=$(stat -c %s "$file" 2>/dev/null) || return 1
    fio --name="rustfs-$rw" --filename="$file" --size="$size" --rw="$rw" --bs="$bs" \
        --direct=1 --ioengine=libaio --iodepth="$depth" \
        --runtime=10 --time_based --group_reporting \
        --output-format=json --output="$json" >/dev/null 2>&1 || return 1
    blkio_fio_value "$json" "$dir" "$metric"
}

# 浮点指标截断为整数，并校验 > 0
blkio_to_int_positive() {
    local value
    value=$(awk -v v="$1" 'BEGIN { printf "%d", int(v + 0) }')
    blkio_is_pos_int "$value" || return 1
    printf '%s\n' "$value"
}

# fio 四组测试，结果写入 BLKIO_PEAK_*；失败返回 1
blkio_peak_from_fio() {
    local file="$1" dir="$2" raw
    raw=$(blkio_fio_run "$file" "$dir/seqread.json" read 1M 8 read bw) || return 1
    BLKIO_PEAK_READ_MIB=$(awk -v v="$raw" 'BEGIN { printf "%d", int(v / 1024) }')
    raw=$(blkio_fio_run "$file" "$dir/seqwrite.json" write 1M 8 write bw) || return 1
    BLKIO_PEAK_WRITE_MIB=$(awk -v v="$raw" 'BEGIN { printf "%d", int(v / 1024) }')
    raw=$(blkio_fio_run "$file" "$dir/randread.json" randread 4k 32 read iops) || return 1
    BLKIO_PEAK_READ_IOPS=$(blkio_to_int_positive "$raw") || return 1
    raw=$(blkio_fio_run "$file" "$dir/randwrite.json" randwrite 4k 32 write iops) || return 1
    BLKIO_PEAK_WRITE_IOPS=$(blkio_to_int_positive "$raw") || return 1
    [ "$BLKIO_PEAK_READ_MIB" -gt 0 ] || return 1
    [ "$BLKIO_PEAK_WRITE_MIB" -gt 0 ] || return 1
    return 0
}

# dd 随机 IOPS 估算；扣除同偏移基线耗时。失败返回 1
# 参数: read|write 文件 总4KiB块数
blkio_dd_random_iops() {
    local mode="$1" file="$2" blocks="$3"
    local ops=128 base_ops=32 i off start end base_start total_ns base_ns denom iops
    start=$(blkio_now_ns) || return 1
    for ((i = 0; i < ops; i++)); do
        off=$(( (RANDOM << 15 | RANDOM) % blocks ))
        if [ "$mode" = read ]; then
            dd if="$file" of=/dev/null bs=4k count=1 skip="$off" iflag=direct status=none 2>/dev/null || return 1
        else
            dd if=/dev/zero of="$file" bs=4k count=1 seek="$off" oflag=direct conv=notrunc status=none 2>/dev/null || return 1
        fi
    done
    end=$(blkio_now_ns) || return 1
    total_ns=$((end - start))

    base_start=$(blkio_now_ns) || return 1
    for ((i = 0; i < base_ops; i++)); do
        if [ "$mode" = read ]; then
            dd if="$file" of=/dev/null bs=4k count=1 skip=0 iflag=direct status=none 2>/dev/null || return 1
        else
            dd if=/dev/zero of="$file" bs=4k count=1 seek=0 oflag=direct conv=notrunc status=none 2>/dev/null || return 1
        fi
    done
    end=$(blkio_now_ns) || return 1
    base_ns=$((end - base_start))

    denom=$((total_ns - base_ns * ops / base_ops))
    [ "$denom" -gt $((total_ns / 8)) ] || return 1
    iops=$((ops * 1000000000 / denom))
    [ "$iops" -ge 10 ] || return 1
    [ "$iops" -le 100000 ] || return 1
    printf '%s\n' "$iops"
}

# 顺序带宽（MiB/s）：优先纳秒计时，不可用时退回 /proc/uptime 厘秒
# 参数: 文件 大小MiB read|write
blkio_seq_mibs() {
    local file="$1" size_mib="$2" mode="$3" start_ns end_ns elapsed_ns start_cs end_cs elapsed_cs
    if start_ns=$(blkio_now_ns); then
        if [ "$mode" = read ]; then
            dd if="$file" of=/dev/null bs=1M count="$size_mib" iflag=direct status=none 2>/dev/null || return 1
        else
            dd if=/dev/zero of="$file" bs=1M count="$size_mib" oflag=direct conv=fsync status=none 2>/dev/null || return 1
        fi
        end_ns=$(blkio_now_ns) || return 1
        elapsed_ns=$((end_ns - start_ns))
        [ "$elapsed_ns" -gt 0 ] || return 1
        printf '%s\n' "$((size_mib * 1000000000 / elapsed_ns))"
        return 0
    fi

    start_cs=$(blkio_now_cs)
    if [ "$mode" = read ]; then
        dd if="$file" of=/dev/null bs=1M count="$size_mib" iflag=direct status=none 2>/dev/null || return 1
    else
        dd if=/dev/zero of="$file" bs=1M count="$size_mib" oflag=direct conv=fsync status=none 2>/dev/null || return 1
    fi
    end_cs=$(blkio_now_cs)
    elapsed_cs=$((end_cs - start_cs))
    [ "$elapsed_cs" -gt 0 ] || return 1
    printf '%s\n' "$((size_mib * 100 / elapsed_cs))"
}

# dd 顺序带宽 + 随机 IOPS，结果写入 BLKIO_PEAK_*；失败返回 1
blkio_peak_from_dd() {
    local file="$1" size_mib="$2"
    BLKIO_PEAK_READ_MIB=$(blkio_seq_mibs "$file" "$size_mib" read) || return 1
    [ "$BLKIO_PEAK_READ_MIB" -gt 0 ] || return 1
    BLKIO_PEAK_WRITE_MIB=$(blkio_seq_mibs "$file" "$size_mib" write) || return 1
    [ "$BLKIO_PEAK_WRITE_MIB" -gt 0 ] || return 1

    if BLKIO_PEAK_READ_IOPS=$(blkio_dd_random_iops read "$file" "$((size_mib * 256))"); then
        BLKIO_PEAK_READ_IOPS_STATIC=0
    else
        BLKIO_PEAK_READ_IOPS=$BLKIO_STATIC_READ_IOPS
        BLKIO_PEAK_READ_IOPS_STATIC=1
        printf "⚠️  随机读 IOPS 不可靠，使用静态值 %s。\n" "$BLKIO_STATIC_READ_IOPS" >&2
    fi
    if BLKIO_PEAK_WRITE_IOPS=$(blkio_dd_random_iops write "$file" "$((size_mib * 256))"); then
        BLKIO_PEAK_WRITE_IOPS_STATIC=0
    else
        BLKIO_PEAK_WRITE_IOPS=$BLKIO_STATIC_WRITE_IOPS
        BLKIO_PEAK_WRITE_IOPS_STATIC=1
        printf "⚠️  随机写 IOPS 不可靠，使用静态值 %s。\n" "$BLKIO_STATIC_WRITE_IOPS" >&2
    fi
    return 0
}

# 测速并把峰值写入 BLKIO_PEAK_*；失败返回 1（调用方使用静态值）
blkio_measure() {
    local size_mib file tmpdir
    BLKIO_PEAK_READ_IOPS_STATIC=0
    BLKIO_PEAK_WRITE_IOPS_STATIC=0
    BLKIO_PEAK_READ_MIB=0
    BLKIO_PEAK_WRITE_MIB=0
    BLKIO_PEAK_READ_IOPS=0
    BLKIO_PEAK_WRITE_IOPS=0
    size_mib=$(blkio_probe_size_mib) || return 1
    file="$SERVICE_DIR/data/.blkio-probe"
    BLKIO_PROBE_FILE="$file"

    printf "🔍 正在测速（预计 40–60 秒，测试文件 %s MiB）...\n" "$size_mib"
    rm -f "$file"
    dd if=/dev/zero of="$file" bs=1M count="$size_mib" oflag=direct conv=fsync status=none 2>/dev/null || {
        blkio_cleanup
        return 1
    }

    if command -v fio >/dev/null 2>&1; then
        if tmpdir=$(mktemp -d); then
            if blkio_peak_from_fio "$file" "$tmpdir"; then
                rm -rf "$tmpdir"
                blkio_cleanup
                return 0
            fi
            rm -rf "$tmpdir"
            printf "⚠️  fio 测速失败，改用 dd 估算。\n" >&2
        else
            printf "⚠️  无法创建 fio 临时目录，改用 dd 估算。\n" >&2
        fi
    fi

    if blkio_peak_from_dd "$file" "$size_mib"; then
        blkio_cleanup
        return 0
    fi
    blkio_cleanup
    return 1
}

# 使用静态保守值作为峰值
blkio_use_static_peaks() {
    BLKIO_PEAK_IS_STATIC=1
    BLKIO_PEAK_READ_MIB=$BLKIO_STATIC_READ_MIB
    BLKIO_PEAK_WRITE_MIB=$BLKIO_STATIC_WRITE_MIB
    BLKIO_PEAK_READ_IOPS=$BLKIO_STATIC_READ_IOPS
    BLKIO_PEAK_WRITE_IOPS=$BLKIO_STATIC_WRITE_IOPS
    BLKIO_PEAK_READ_IOPS_STATIC=1
    BLKIO_PEAK_WRITE_IOPS_STATIC=1
}

# 确定限速设备；成功 0，无法限速 1，EOF 中止 2
resolve_blkio_device() {
    local detected device
    detected=$(blkio_detect_device) || detected=""

    if [ -n "$detected" ] && [ ! -b "$detected" ]; then
        printf "⚠️  数据目录所在位置 '%s' 不是块设备，跳过 I/O 限速。\n" "$detected" >&2
        return 1
    fi
    [ -n "$detected" ] || printf "⚠️  未能自动探测数据目录所在块设备，请手动输入。\n"

    while true; do
        if [ -n "$detected" ]; then
            printf "请输入需要限速的块设备 [%s]: " "$detected"
        else
            printf "请输入需要限速的块设备: "
        fi
        if ! read -r device; then
            [ -n "$device" ] || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 2; }
        fi
        device="${device:-$detected}"
        if [ -z "$device" ]; then
            printf "❌ 设备路径不能为空。\n" >&2
            continue
        fi
        if [ ! -b "$device" ]; then
            printf "❌ '%s' 不是块设备，请重新输入。\n" "$device" >&2
            continue
        fi
        if [ -n "$detected" ] && [ "$device" != "$detected" ]; then
            printf "⚠️  该设备与数据目录所在设备不同，限速可能不作用于 rustfs 的实际 I/O。\n"
        fi
        BLKIO_DEVICE="$device"
        return 0
    done
}

# 读取一项正整数上限；EOF 返回 2
blkio_read_limit() {
    local label="$1" default="$2" var_name="$3" value
    while true; do
        printf "  %s [%s]: " "$label" "$default"
        if ! read -r value; then
            [ -n "$value" ] || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 2; }
        fi
        value="${value:-$default}"
        if blkio_is_pos_int "$value"; then
            printf -v "$var_name" '%s' "$value"
            return 0
        fi
        printf "❌ 请输入正整数（不要带单位）。\n" >&2
    done
}

# 计算建议值并逐项确认；单项静态项直接使用静态值；EOF 返回 2
blkio_ask_limits() {
    local rd_bps wr_bps rd_iops wr_iops rd_note="" wr_note=""
    if [ "$BLKIO_PEAK_IS_STATIC" = 1 ]; then
        rd_bps=$BLKIO_STATIC_READ_MIB
        wr_bps=$BLKIO_STATIC_WRITE_MIB
        rd_iops=$BLKIO_STATIC_READ_IOPS
        wr_iops=$BLKIO_STATIC_WRITE_IOPS
    else
        [ "$BLKIO_PEAK_READ_IOPS_STATIC" = 1 ] && rd_note="（静态）"
        [ "$BLKIO_PEAK_WRITE_IOPS_STATIC" = 1 ] && wr_note="（静态）"
        printf "📊 测速结果（%s）：\n" "$BLKIO_DEVICE"
        printf "  顺序读 %s MiB/s    顺序写 %s MiB/s\n" "$BLKIO_PEAK_READ_MIB" "$BLKIO_PEAK_WRITE_MIB"
        printf "  随机读 %s IOPS%s    随机写 %s IOPS%s\n" \
            "$BLKIO_PEAK_READ_IOPS" "$rd_note" "$BLKIO_PEAK_WRITE_IOPS" "$wr_note"
        rd_bps=$(blkio_scale "$BLKIO_PEAK_READ_MIB" "$BLKIO_SUGGEST_PERCENT")
        wr_bps=$(blkio_scale "$BLKIO_PEAK_WRITE_MIB" "$BLKIO_SUGGEST_PERCENT")
        if [ "$BLKIO_PEAK_READ_IOPS_STATIC" = 1 ]; then
            rd_iops=$BLKIO_STATIC_READ_IOPS
        else
            rd_iops=$(blkio_scale "$BLKIO_PEAK_READ_IOPS" "$BLKIO_SUGGEST_PERCENT")
        fi
        if [ "$BLKIO_PEAK_WRITE_IOPS_STATIC" = 1 ]; then
            wr_iops=$BLKIO_STATIC_WRITE_IOPS
        else
            wr_iops=$(blkio_scale "$BLKIO_PEAK_WRITE_IOPS" "$BLKIO_SUGGEST_PERCENT")
        fi
    fi

    printf "请确认限速上限（带宽单位固定为 MiB/s，IOPS 直接输入次数；只输入数字，回车采用建议值）\n"
    blkio_read_limit "读带宽上限 (MiB/s)" "$rd_bps" BLKIO_READ_LIMIT_MIB || return 2
    blkio_read_limit "写带宽上限 (MiB/s)" "$wr_bps" BLKIO_WRITE_LIMIT_MIB || return 2
    blkio_read_limit "读 IOPS 上限" "$rd_iops" BLKIO_READ_LIMIT_IOPS || return 2
    blkio_read_limit "写 IOPS 上限" "$wr_iops" BLKIO_WRITE_LIMIT_IOPS || return 2
    return 0
}

# 删除模板中的 blkio 段（标记不成对或无标记时不做任何事）
blkio_remove_config() {
    local compose="$1"
    grep -q '^[[:space:]]*# __BLKIO_BEGIN__$' "$compose" || return 0
    grep -q '^[[:space:]]*# __BLKIO_END__$' "$compose" || return 0
    sed -i '/^[[:space:]]*# __BLKIO_BEGIN__$/,/^[[:space:]]*# __BLKIO_END__$/d' "$compose" || return 1
}

# 替换占位符并删除标记行
blkio_render_config() {
    local compose="$1"
    sed -i \
        -e "s|__BLKIO_DEVICE__|$(sed_escape "$BLKIO_DEVICE")|g" \
        -e "s|__BLKIO_READ_BPS__|$(blkio_format_bps "$BLKIO_READ_LIMIT_MIB")|g" \
        -e "s|__BLKIO_WRITE_BPS__|$(blkio_format_bps "$BLKIO_WRITE_LIMIT_MIB")|g" \
        -e "s|__BLKIO_READ_IOPS__|$BLKIO_READ_LIMIT_IOPS|g" \
        -e "s|__BLKIO_WRITE_IOPS__|$BLKIO_WRITE_LIMIT_IOPS|g" \
        "$compose" || return 1
    sed -i -e '/^[[:space:]]*# __BLKIO_BEGIN__$/d' -e '/^[[:space:]]*# __BLKIO_END__$/d' "$compose" || return 1
    return 0
}

# 安装流程入口：成功 0；无法限速 0（已删除配置）；EOF/写入失败 2
apply_blkio_limits() {
    local compose="$1" rc saved_traps
    [ -f "$compose" ] || {
        printf "❌ compose 文件不存在: %s\n" "$compose" >&2
        return 2
    }
    BLKIO_PEAK_IS_STATIC=0

    resolve_blkio_device
    rc=$?
    if [ "$rc" -eq 2 ]; then
        return 2
    elif [ "$rc" -ne 0 ]; then
        if ! blkio_remove_config "$compose"; then
            printf "❌ 无法移除 blkio 配置段: %s\n" "$compose" >&2
            return 2
        fi
        return 0
    fi

    saved_traps=$(trap -p EXIT INT TERM HUP)
    trap 'blkio_cleanup' EXIT
    trap 'blkio_cleanup; exit 130' INT
    trap 'blkio_cleanup; exit 143' TERM
    trap 'blkio_cleanup; exit 129' HUP
    if ! blkio_measure; then
        printf "⚠️  测速不可用，使用静态保守值。\n"
        blkio_use_static_peaks
    fi
    blkio_cleanup
    trap - EXIT INT TERM HUP
    if [ -n "$saved_traps" ]; then
        eval "$saved_traps"
    fi

    blkio_ask_limits || return 2
    blkio_render_config "$compose" || {
        printf "❌ 写入 blkio 配置失败: %s\n" "$compose" >&2
        return 2
    }
    printf "✅ 已写入 blkio 限速：读 %smib、写 %smib、读 %s IOPS、写 %s IOPS\n" \
        "$BLKIO_READ_LIMIT_MIB" "$BLKIO_WRITE_LIMIT_MIB" \
        "$BLKIO_READ_LIMIT_IOPS" "$BLKIO_WRITE_LIMIT_IOPS"
    return 0
}
