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

printf -- "----------------------------------------\n"
printf "通过 %d，失败 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
