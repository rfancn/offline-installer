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

assert_rc() {
    local expected="$1" desc="$2"
    shift 2
    local rc
    "$@" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq "$expected" ]; then
        PASS=$((PASS + 1)); printf "✅ %s\n" "$desc"
    else
        FAIL=$((FAIL + 1)); printf "❌ %s：期望 rc=%s，实际 rc=%s\n" "$desc" "$expected" "$rc"
    fi
}

assert_file_contains() {
    local desc="$1" file="$2" pattern="$3"
    if grep -q -- "$pattern" "$file"; then
        PASS=$((PASS + 1)); printf "✅ %s\n" "$desc"
    else
        FAIL=$((FAIL + 1)); printf "❌ %s：未找到 '%s'\n" "$desc" "$pattern"
    fi
}

assert_file_not_contains() {
    local desc="$1" file="$2" pattern="$3"
    if grep -q -- "$pattern" "$file"; then
        FAIL=$((FAIL + 1)); printf "❌ %s：不应出现 '%s'\n" "$desc" "$pattern"
    else
        PASS=$((PASS + 1)); printf "✅ %s\n" "$desc"
    fi
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
            "job options" : {
                "rw" : "write",
                "bs" : "1M"
            },
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

cat > "$TMP_DIR/fio-write.json" <<'EOF'
{
    "jobs" : [
        {
            "jobname" : "rustfs-seqwrite",
            "job options" : {
                "rw" : "write",
                "bs" : "1M"
            },
            "read" : {
                "bw" : 111,
                "iops" : 0
            },
            "write" : {
                "bw" : 222,
                "iops" : 0
            }
        }
    ]
}
EOF
assert_eq "含 job options 时读带宽正确" "111" "$(blkio_fio_value_awk "$TMP_DIR/fio-write.json" read bw)"
assert_eq "含 job options 时写带宽正确" "222" "$(blkio_fio_value_awk "$TMP_DIR/fio-write.json" write bw)"

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

# ---- fio 执行路径 ----
mkdir -p "$TMP_DIR/fakefio" "$TMP_DIR/fio-json"
cat > "$TMP_DIR/fakefio/fio" <<'EOF'
#!/bin/sh
out="" rw=""
for arg in "$@"; do
    case "$arg" in
        --output=*) out="${arg#--output=}" ;;
        --rw=*) rw="${arg#--rw=}" ;;
    esac
done
case "$rw" in
    read)
        printf '{"jobs":[{"read":{"bw":421888,"iops":1024.5},"write":{"bw":0,"iops":0}}]}\n' > "$out" ;;
    write)
        printf '{"jobs":[{"read":{"bw":0,"iops":0},"write":{"bw":200704,"iops":512}}]}\n' > "$out" ;;
    randread)
        printf '{"jobs":[{"read":{"bw":0,"iops":1024.5},"write":{"bw":0,"iops":0}}]}\n' > "$out" ;;
    randwrite)
        printf '{"jobs":[{"read":{"bw":0,"iops":0},"write":{"bw":0,"iops":512}}]}\n' > "$out" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/fakefio/fio"
: > "$TMP_DIR/fio-probe"
fio_peak_with_fake() {
    PATH="$TMP_DIR/fakefio:$PATH" blkio_peak_from_fio "$TMP_DIR/fio-probe" "$TMP_DIR/fio-json"
}
assert_true "fio 四组峰值提取成功" fio_peak_with_fake
assert_eq "fio 顺序读 MiB/s" "412" "$BLKIO_PEAK_READ_MIB"
assert_eq "fio 顺序写 MiB/s" "196" "$BLKIO_PEAK_WRITE_MIB"
assert_eq "fio 随机读 IOPS" "1024" "$BLKIO_PEAK_READ_IOPS"
assert_eq "fio 随机写 IOPS" "512" "$BLKIO_PEAK_WRITE_IOPS"

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

# ---- 建议值与逐项确认 ----
BLKIO_PEAK_IS_STATIC=0
BLKIO_DEVICE=/dev/md0
BLKIO_PEAK_READ_MIB=412
BLKIO_PEAK_WRITE_MIB=385
BLKIO_PEAK_READ_IOPS=2010
BLKIO_PEAK_WRITE_IOPS=725
BLKIO_PEAK_READ_IOPS_STATIC=0
BLKIO_PEAK_WRITE_IOPS_STATIC=0
blkio_ask_limits <<< $'\n\n\n\n'
assert_eq "默认建议读带宽" "329" "$BLKIO_READ_LIMIT_MIB"
assert_eq "默认建议写带宽" "308" "$BLKIO_WRITE_LIMIT_MIB"
assert_eq "默认建议读 IOPS" "1608" "$BLKIO_READ_LIMIT_IOPS"
assert_eq "默认建议写 IOPS" "580" "$BLKIO_WRITE_LIMIT_IOPS"

BLKIO_PEAK_IS_STATIC=0
BLKIO_PEAK_READ_IOPS_STATIC=0
BLKIO_PEAK_WRITE_IOPS_STATIC=0
blkio_ask_limits <<< $'100\n50\n10\n20\n'
assert_eq "手工覆盖读带宽" "100" "$BLKIO_READ_LIMIT_MIB"
assert_eq "手工覆盖写带宽" "50" "$BLKIO_WRITE_LIMIT_MIB"
assert_eq "手工覆盖读 IOPS" "10" "$BLKIO_READ_LIMIT_IOPS"
assert_eq "手工覆盖写 IOPS" "20" "$BLKIO_WRITE_LIMIT_IOPS"

BLKIO_PEAK_IS_STATIC=0
BLKIO_PEAK_READ_IOPS_STATIC=0
BLKIO_PEAK_WRITE_IOPS_STATIC=0
blkio_ask_limits <<< $'300mib\n\n\n\n\n'
assert_eq "非法输入后回车取默认值" "329" "$BLKIO_READ_LIMIT_MIB"

BLKIO_PEAK_IS_STATIC=0
BLKIO_PEAK_READ_MIB=412
BLKIO_PEAK_WRITE_MIB=385
BLKIO_PEAK_READ_IOPS=1999
BLKIO_PEAK_WRITE_IOPS=777
BLKIO_PEAK_READ_IOPS_STATIC=1
BLKIO_PEAK_WRITE_IOPS_STATIC=1
blkio_ask_limits <<< $'\n\n\n\n'
assert_eq "单项静态读带宽仍折算" "329" "$BLKIO_READ_LIMIT_MIB"
assert_eq "单项静态写带宽仍折算" "308" "$BLKIO_WRITE_LIMIT_MIB"
assert_eq "单项静态读 IOPS 不再折算" "400" "$BLKIO_READ_LIMIT_IOPS"
assert_eq "单项静态写 IOPS 不再折算" "80" "$BLKIO_WRITE_LIMIT_IOPS"

BLKIO_PEAK_IS_STATIC=1
blkio_ask_limits <<< $'\n\n\n\n'
assert_eq "全静态读带宽" "250" "$BLKIO_READ_LIMIT_MIB"
assert_eq "全静态写带宽" "120" "$BLKIO_WRITE_LIMIT_MIB"
assert_eq "全静态读 IOPS" "400" "$BLKIO_READ_LIMIT_IOPS"
assert_eq "全静态写 IOPS" "80" "$BLKIO_WRITE_LIMIT_IOPS"

ask_limits_eof() { blkio_ask_limits </dev/null; }
read_limit_eof() { blkio_read_limit dummy 5 DUMMY_VALUE </dev/null; }
assert_rc 2 "ask_limits EOF 中止" ask_limits_eof
assert_rc 2 "read_limit EOF 中止" read_limit_eof

# ---- 渲染与删除 ----
cat > "$TMP_DIR/compose.yml" <<'EOF'
services:
  rustfs:
    image: rustfs/rustfs:latest
    restart: unless-stopped
    # __BLKIO_BEGIN__
    blkio_config:
      weight: 500
      device_read_bps:
        - path: __BLKIO_DEVICE__
          rate: "__BLKIO_READ_BPS__"
      device_write_bps:
        - path: __BLKIO_DEVICE__
          rate: "__BLKIO_WRITE_BPS__"
      device_read_iops:
        - path: __BLKIO_DEVICE__
          rate: __BLKIO_READ_IOPS__
      device_write_iops:
        - path: __BLKIO_DEVICE__
          rate: __BLKIO_WRITE_IOPS__
    # __BLKIO_END__
EOF

BLKIO_DEVICE=/dev/md0
BLKIO_READ_LIMIT_MIB=329
BLKIO_WRITE_LIMIT_MIB=308
BLKIO_READ_LIMIT_IOPS=1608
BLKIO_WRITE_LIMIT_IOPS=580
blkio_render_config "$TMP_DIR/compose.yml"
assert_file_contains "设备路径已替换" "$TMP_DIR/compose.yml" "path: /dev/md0"
assert_file_contains "读带宽已替换" "$TMP_DIR/compose.yml" 'rate: "329mib"'
assert_file_contains "写带宽已替换" "$TMP_DIR/compose.yml" 'rate: "308mib"'
assert_file_contains "读 IOPS 已替换" "$TMP_DIR/compose.yml" "rate: 1608"
assert_file_contains "写 IOPS 已替换" "$TMP_DIR/compose.yml" "rate: 580"
assert_file_not_contains "占位符全部替换" "$TMP_DIR/compose.yml" "__BLKIO_"
assert_file_not_contains "标记行已删除" "$TMP_DIR/compose.yml" "__BLKIO_BEGIN__"
assert_file_contains "无关 YAML 配置保留" "$TMP_DIR/compose.yml" "restart: unless-stopped"

cp "$TMP_DIR/compose.yml" "$TMP_DIR/compose-first.yml"
blkio_render_config "$TMP_DIR/compose.yml"
assert_true "重复渲染保持幂等" cmp -s "$TMP_DIR/compose-first.yml" "$TMP_DIR/compose.yml"

cat > "$TMP_DIR/compose-nomarker.yml" <<'EOF'
services:
  rustfs:
    image: rustfs/rustfs:latest
EOF
cp "$TMP_DIR/compose-nomarker.yml" "$TMP_DIR/compose-nomarker-before.yml"
blkio_remove_config "$TMP_DIR/compose-nomarker.yml"
assert_true "无标记文件删除为 no-op" cmp -s "$TMP_DIR/compose-nomarker-before.yml" "$TMP_DIR/compose-nomarker.yml"

cat > "$TMP_DIR/compose-unpaired.yml" <<'EOF'
services:
  rustfs:
    image: rustfs/rustfs:latest
    # __BLKIO_BEGIN__
    keep: yes
EOF
blkio_remove_config "$TMP_DIR/compose-unpaired.yml"
assert_file_contains "标记不成对时不删除" "$TMP_DIR/compose-unpaired.yml" "keep: yes"
assert_false "标记不成对返回失败" blkio_remove_config "$TMP_DIR/compose-unpaired.yml"

cat > "$TMP_DIR/compose-remove.yml" <<'EOF'
services:
  rustfs:
    image: rustfs/rustfs:latest
    # __BLKIO_BEGIN__
    blkio_config:
      weight: 500
    # __BLKIO_END__
EOF
blkio_remove_config "$TMP_DIR/compose-remove.yml"
assert_file_not_contains "blkio 段已删除" "$TMP_DIR/compose-remove.yml" "blkio_config"
assert_file_contains "其余配置保留" "$TMP_DIR/compose-remove.yml" "image: rustfs/rustfs:latest"

cat > "$TMP_DIR/compose-extra.yml" <<'EOF'
services:
  rustfs:
    # __BLKIO_BEGIN__
    blkio_config:
      weight: 500
    # __BLKIO_END__
    note: __BLKIO_UNKNOWN__
EOF
assert_false "渲染后仍有占位符时失败" blkio_render_config "$TMP_DIR/compose-extra.yml"

# ---- 真实模板占位符 ----
for tpl in "$TEST_DIR/../resource/docker-compose.yml" "$TEST_DIR/../resource/docker-compose.direct.yml"; do
    name=$(basename "$tpl")
    cp "$tpl" "$TMP_DIR/real-$name"
    assert_eq "真实模板占位符数量: $name" "10" "$(grep -c '__BLKIO_' "$TMP_DIR/real-$name")"
    BLKIO_DEVICE=/dev/md0
    BLKIO_READ_LIMIT_MIB=329
    BLKIO_WRITE_LIMIT_MIB=308
    BLKIO_READ_LIMIT_IOPS=1608
    BLKIO_WRITE_LIMIT_IOPS=580
    blkio_render_config "$TMP_DIR/real-$name"
    assert_file_not_contains "真实模板渲染无残留: $name" "$TMP_DIR/real-$name" "__BLKIO_"
done

# ---- apply 编排 ----
run_apply_case() {
    local compose="$1" log="$TMP_DIR/apply.log"
    : > "$log"
    (
        # 清除从测试主进程继承的 EXIT trap，避免 apply 恢复 trap 后提前删除 TMP_DIR
        trap - EXIT
        resolve_blkio_device() { printf 'resolve\n' >> "$log"; return "${RESOLVE_RC:-0}"; }
        blkio_measure() { printf 'measure\n' >> "$log"; return "${MEASURE_RC:-0}"; }
        blkio_use_static_peaks() { printf 'static\n' >> "$log"; }
        blkio_ask_limits() { printf 'ask\n' >> "$log"; return "${ASK_RC:-0}"; }
        blkio_render_config() { printf 'render\n' >> "$log"; return "${RENDER_RC:-0}"; }
        blkio_remove_config() { printf 'remove\n' >> "$log"; return "${REMOVE_RC:-0}"; }
        blkio_cleanup() { :; }
        apply_blkio_limits "$compose" >/dev/null 2>&1
        printf 'rc=%s log=%s trap=%s\n' "$?" "$(paste -sd, "$log")" "$(trap -p INT)"
    )
}
apply_yml="$TMP_DIR/apply.yml"
: > "$apply_yml"
assert_eq "compose 缺失时中止" "rc=2 log= trap=" \
    "$(run_apply_case "$TMP_DIR/missing.yml")"
assert_eq "resolve EOF 时中止且不测速" "rc=2 log=resolve trap=" \
    "$(RESOLVE_RC=2 run_apply_case "$apply_yml")"
assert_eq "无法限速时删除配置并成功返回" "rc=0 log=resolve,remove trap=" \
    "$(RESOLVE_RC=1 run_apply_case "$apply_yml")"
assert_eq "测速失败时走静态值并继续" "rc=0 log=resolve,measure,static,ask,render trap=" \
    "$(MEASURE_RC=1 run_apply_case "$apply_yml")"
assert_eq "确认阶段 EOF 中止且不渲染" "rc=2 log=resolve,measure,ask trap=" \
    "$(ASK_RC=2 run_apply_case "$apply_yml")"
assert_eq "渲染失败时中止" "rc=2 log=resolve,measure,ask,render trap=" \
    "$(RENDER_RC=1 run_apply_case "$apply_yml")"
assert_eq "成功路径不残留 trap" "rc=0 log=resolve,measure,ask,render trap=" \
    "$(run_apply_case "$apply_yml")"

# ---- 信号中断清理 ----
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
mkdir -p "$TMP_DIR/data"
: > "$TMP_DIR/compose.yml"
mkfifo "$TMP_DIR/int-fifo"
cat > "$TMP_DIR/int-run.sh" <<EOF
#!/bin/bash
set -u
. "$REPO_ROOT/script/common.sh"
. "$REPO_ROOT/app/rustfs/blkio.sh"
SERVICE_DIR="$TMP_DIR"
resolve_blkio_device() { BLKIO_DEVICE=/dev/null; return 0; }
blkio_measure() {
    BLKIO_PROBE_FILE="\$SERVICE_DIR/data/.blkio-probe"
    : > "\$BLKIO_PROBE_FILE"
    : > "\$SERVICE_DIR/int-ready"
    read -r _ < "\$SERVICE_DIR/int-fifo"
}
blkio_ask_limits() { :; }
blkio_render_config() { :; }
apply_blkio_limits "\$SERVICE_DIR/compose.yml"
EOF
# 开启 job control，使后台脚本不继承被忽略的 SIGINT，trap 才能生效
set -m
bash "$TMP_DIR/int-run.sh" >"$TMP_DIR/int.out" 2>&1 &
int_pid=$!
set +m
for _ in $(seq 1 100); do
    [ -f "$TMP_DIR/int-ready" ] && break
    sleep 0.05
done
kill -INT "$int_pid"
wait "$int_pid"
int_rc=$?
assert_eq "中断退出码 130" "130" "$int_rc"
assert_false "中断后探测文件被清理" [ -f "$TMP_DIR/data/.blkio-probe" ]

printf -- "----------------------------------------\n"
printf "通过 %d，失败 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
