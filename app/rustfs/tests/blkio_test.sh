#!/bin/bash
# blkio.sh 纯函数单元测试：不触碰真实块设备
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TEST_DIR/../../../script/common.sh"
. "$TEST_DIR/../blkio.sh" || { printf "❌ 无法加载 blkio.sh\n" >&2; exit 1; }

TMP_DIR=$(mktemp -d) || { printf "❌ 无法创建临时目录\n" >&2; exit 1; }
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf "✅ %s\n" "$desc"
    else
        FAIL=$((FAIL + 1)); printf "❌ %s：期望 '%s'，实际 '%s'\n" "$desc" "$expected" "$actual"
    fi
}

assert_true() {
    local desc="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); printf "✅ %s\n" "$desc"
    else
        FAIL=$((FAIL + 1)); printf "❌ %s：期望返回成功\n" "$desc"
    fi
}

assert_false() {
    local desc="$1"; shift
    local rc
    "$@" >/dev/null 2>&1
    rc=$?
    case "$rc" in
        1) PASS=$((PASS + 1)); printf "✅ %s\n" "$desc" ;;
        0) FAIL=$((FAIL + 1)); printf "❌ %s：期望返回失败\n" "$desc" ;;
        *) FAIL=$((FAIL + 1)); printf "❌ %s：命令异常（rc=%s）\n" "$desc" "$rc" ;;
    esac
}

# ---- 纯函数 ----
assert_eq "剥离子卷后缀" "/dev/sda1" "$(blkio_strip_subvol '/dev/sda1[/@]')"
assert_eq "普通设备原样返回" "/dev/md0" "$(blkio_strip_subvol '/dev/md0')"
assert_true "正整数 1 合法" blkio_is_pos_int 1
assert_false "0 不合法" blkio_is_pos_int 0
assert_false "带单位不合法" blkio_is_pos_int 300mib
assert_false "负数不合法" blkio_is_pos_int -1
assert_eq "412 × 80% 向下取整" "329" "$(blkio_scale 412 80)"
assert_eq "605 × 80% 向下取整" "484" "$(blkio_scale 605 80)"
assert_eq "最小值 1" "1" "$(blkio_scale 1 10)"
assert_eq "BPS 格式" "329mib" "$(blkio_format_bps 329)"

# ---- 边界与清理 ----
assert_false "前导零不合法" blkio_is_pos_int 007
assert_false "超大整数不合法" blkio_is_pos_int 1234567890123
assert_false "scale 拒绝非数字" blkio_scale abc 80
assert_false "scale 拒绝 0 百分比" blkio_scale 100 0
probe="$TMP_DIR/.blkio-probe"
: > "$probe"
BLKIO_PROBE_FILE="$probe"
blkio_cleanup
assert_false "cleanup 删除探测文件" [ -f "$probe" ]
assert_true "cleanup 可重复调用" blkio_cleanup

# ---- fio JSON 解析 ----
cat > "$TMP_DIR/fio.json" <<'EOF'
{
    "fio version" : "fio-3.35",
    "jobs" : [
        {
            "jobname" : "rustfs-randread",
            "groupid" : 0,
            "error" : 0,
            "read" : {
                "io_bytes" : 4294967296,
                "bw" : 421888,
                "bw_min" : 400000,
                "bw_max" : 430000,
                "bw_bytes" : 432013312,
                "iops" : 1024.5,
                "iops_min" : 900.0,
                "iops_max" : 1100.0
            },
            "write" : {
                "io_bytes" : 0,
                "bw" : 0,
                "bw_bytes" : 0,
                "iops" : 0
            },
            "trim" : {
                "io_bytes" : 0,
                "bw" : 0,
                "iops" : 0
            },
            "sync" : {
                "total_ios" : 0
            }
        }
    ]
}
EOF
assert_eq "awk 解析读带宽" "421888" "$(blkio_fio_value_awk "$TMP_DIR/fio.json" read bw)"
assert_eq "awk 解析读 IOPS" "1024.5" "$(blkio_fio_value_awk "$TMP_DIR/fio.json" read iops)"
assert_eq "awk 解析写带宽" "0" "$(blkio_fio_value_awk "$TMP_DIR/fio.json" write bw)"
assert_eq "解析入口读带宽" "421888" "$(blkio_fio_value "$TMP_DIR/fio.json" read bw)"
assert_eq "解析入口读 IOPS" "1024.5" "$(blkio_fio_value "$TMP_DIR/fio.json" read iops)"
assert_eq "解析入口零值" "0" "$(blkio_fio_value "$TMP_DIR/fio.json" write bw)"

cat > "$TMP_DIR/fio-bad.json" <<'EOF'
{
    "jobs" : [
        {
            "read" : {
                "bw" : "abc",
                "iops" : null
            }
        }
    ]
}
EOF
assert_false "缺失文件返回失败" blkio_fio_value "$TMP_DIR/nope.json" read bw
assert_false "缺失指标返回失败" blkio_fio_value "$TMP_DIR/fio.json" read missing
assert_false "字符串指标返回失败" blkio_fio_value "$TMP_DIR/fio-bad.json" read bw
assert_false "null 指标返回失败" blkio_fio_value "$TMP_DIR/fio-bad.json" read iops

# PATH 垫片：屏蔽 jq 或 jq+python3，验证回退路径
mkdir -p "$TMP_DIR/nojq" "$TMP_DIR/nojqpy"
printf '#!/bin/sh\nexit 127\n' > "$TMP_DIR/nojq/jq"
printf '#!/bin/sh\nexit 127\n' > "$TMP_DIR/nojqpy/jq"
printf '#!/bin/sh\nexit 127\n' > "$TMP_DIR/nojqpy/python3"
chmod +x "$TMP_DIR/nojq/jq" "$TMP_DIR/nojqpy/jq" "$TMP_DIR/nojqpy/python3"
assert_eq "回退到 python3 解析读带宽" "421888" \
    "$(PATH="$TMP_DIR/nojq:$PATH" blkio_fio_value "$TMP_DIR/fio.json" read bw)"
assert_eq "回退到 awk 解析读带宽" "421888" \
    "$(PATH="$TMP_DIR/nojqpy:$PATH" blkio_fio_value "$TMP_DIR/fio.json" read bw)"

# ---- 设备探测与测速纯逻辑 ----
mkdir -p "$TMP_DIR/fakebin" "$TMP_DIR/probe-data"
cat > "$TMP_DIR/fakebin/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/mock 1000000 0 %s 0%% /mock\n' "${DF_AVAIL_KB:-0}"
EOF
chmod +x "$TMP_DIR/fakebin/df"
SERVICE_DIR="$TMP_DIR"
probe_size_with() {
    DF_AVAIL_KB="$1" PATH="$TMP_DIR/fakebin:$PATH" blkio_probe_size_mib
}
assert_eq "可用空间 1 GiB 取四分之一" "256" "$(probe_size_with 1048576)"
assert_eq "可用空间充足时封顶 1 GiB" "1024" "$(probe_size_with 8388608)"
assert_false "空间不足返回失败" probe_size_with 102400
assert_false "df 输出非法返回失败" probe_size_with abc
assert_false "0.9 截断后为 0 应失败" blkio_to_int_positive 0.9
assert_false "非数字指标应失败" blkio_to_int_positive abc
assert_false "超过 9 位应失败" blkio_to_int_positive 1000000000

# ---- dd 回退的单项降级 ----
# 计时器在命令替换子 shell 中运行，用文件记录调用序号才能跨调用递增
fake_ns_init() {
    _ns_seq="$TMP_DIR/ns-seq.txt"
    : > "$_ns_seq"
    blkio_now_ns() {
        local idx
        idx=$(( $(wc -l < "$_ns_seq") + 1 ))
        printf 'x\n' >> "$_ns_seq"
        printf '%s\n' "$((idx * 100000000))"
    }
}
dd_fallback_out=$(
    dd() { :; }
    fake_ns_init
    blkio_dd_random_iops() { return 1; }
    BLKIO_PEAK_READ_IOPS_STATIC=0
    BLKIO_PEAK_WRITE_IOPS_STATIC=0
    if blkio_peak_from_dd /nonexistent 64 2>/dev/null; then
        printf '0,%s,%s,%s,%s,%s,%s\n' "$BLKIO_PEAK_READ_MIB" "$BLKIO_PEAK_WRITE_MIB" \
            "$BLKIO_PEAK_READ_IOPS" "$BLKIO_PEAK_WRITE_IOPS" \
            "$BLKIO_PEAK_READ_IOPS_STATIC" "$BLKIO_PEAK_WRITE_IOPS_STATIC"
    else
        printf '1\n'
    fi
)
assert_eq "随机 IOPS 失败仍保留顺序带宽并回退静态值" \
    "0,640,640,400,80,1,1" "$dd_fallback_out"

dd_success_out=$(
    dd() { :; }
    fake_ns_init
    blkio_dd_random_iops() {
        case "$1" in
            read) printf '5000\n' ;;
            write) printf '3000\n' ;;
        esac
    }
    BLKIO_PEAK_READ_IOPS_STATIC=0
    BLKIO_PEAK_WRITE_IOPS_STATIC=0
    if blkio_peak_from_dd /nonexistent 64 2>/dev/null; then
        printf '0,%s,%s,%s,%s,%s,%s\n' "$BLKIO_PEAK_READ_MIB" "$BLKIO_PEAK_WRITE_MIB" \
            "$BLKIO_PEAK_READ_IOPS" "$BLKIO_PEAK_WRITE_IOPS" \
            "$BLKIO_PEAK_READ_IOPS_STATIC" "$BLKIO_PEAK_WRITE_IOPS_STATIC"
    else
        printf '1\n'
    fi
)
assert_eq "随机 IOPS 成功时不置静态标志" "0,640,640,5000,3000,0,0" "$dd_success_out"

# ---- 随机 IOPS 可信区间 ----
run_dd_random_with_ns() {
    (
        dd() { :; }
        _seq="$TMP_DIR/ns-seq.txt"
        _log="$TMP_DIR/ns-log.txt"
        printf '%s\n' "$1" > "$_seq"
        : > "$_log"
        blkio_now_ns() {
            local idx value
            idx=$(( $(wc -l < "$_log") + 1 ))
            printf 'x\n' >> "$_log"
            value=$(sed -n "${idx}p" "$_seq")
            [ -n "$value" ] || return 1
            printf '%s\n' "$value"
        }
        blkio_dd_random_iops read /nonexistent 1
    )
}
assert_eq "随机 IOPS 信噪比达标时输出" "64000" \
    "$(run_dd_random_with_ns $'0\n10000000\n10000000\n12000000')"
assert_false "信噪比不足时失败" run_dd_random_with_ns $'0\n16000000\n16000000\n19500000'
assert_false "超过 IOPS 上界时失败" run_dd_random_with_ns $'0\n10000000\n10000000\n12180250'

printf -- "----------------------------------------\n"
printf "通过 %d，失败 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
