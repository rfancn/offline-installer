#!/bin/sh
set -eu

# ========== 加载脚本同目录下的 .env ==========
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  . "$SCRIPT_DIR/.env"
  set +a
fi

ALIAS="rustfs"
ENDPOINT="${RUSTFS_ENDPOINT:-http://localhost:9000}"

# 清理使用 root 凭据（需要 List/Delete/AbortMultipartUpload 权限）
ADMIN_AK="${RUSTFS_ACCESS_KEY:?请设置 RUSTFS_ACCESS_KEY}"
ADMIN_SK="${RUSTFS_SECRET_KEY:?请设置 RUSTFS_SECRET_KEY}"

BUCKET=file-transfer

usage() {
  cat <<'EOF'
用法:
  ft-clean.sh
  ft-clean.sh copyout <路径> [--yes]

  copyout <路径> [--yes]   递归删除 copyout/<路径>/ 下所有对象（不判断日期）

默认清理 copyin/ 下 7 天前的过期目录与未完成分片。
EOF
  exit 1
}

# 指定路径删除模式：ft-clean.sh copyout <相对路径> [--yes]
if [ $# -ge 2 ] && [ "$1" = "copyout" ]; then
  TARGET_DIR="copyout"
  TARGET_PATH="${2%/}"
  shift 2

  ASSUME_YES=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) ASSUME_YES=1; shift ;;
      *) echo "❌ 未知参数: $1" >&2; usage ;;
    esac
  done

  case "$TARGET_PATH" in
    ''|/*|*..*)
      echo "❌ 路径不能为空、不能以 / 开头、不能包含 .." >&2
      exit 1 ;;
  esac

  mc alias set "$ALIAS" "$ENDPOINT" "$ADMIN_AK" "$ADMIN_SK" >/dev/null

  if [ "$ASSUME_YES" -ne 1 ]; then
    printf "⚠️ 将递归删除 %s/%s/ 下所有对象，不可恢复。输入 yes 继续: " \
      "$TARGET_DIR" "$TARGET_PATH"
    read -r confirm || { echo; echo "已取消"; exit 1; }
    [ "$confirm" = "yes" ] || { echo "已取消"; exit 1; }
  fi

  PREFIX="$ALIAS/$BUCKET/$TARGET_DIR/$TARGET_PATH"
  echo "删除: $BUCKET/$TARGET_DIR/$TARGET_PATH/"

  # 删除前缀下所有对象
  mc rm --recursive --force "$PREFIX/"

  # 若桶启用了版本控制，删除所有历史版本与删除标记
  mc rm --recursive --force --versions "$PREFIX/" 2>/dev/null || true

  # 清理残留的空目录标记对象（key 以 / 结尾）
  mc ls --recursive "$PREFIX/" 2>/dev/null | awk '{print $NF}' | while read -r key; do
    case "$key" in
      */) mc rm --force "$PREFIX/$key" 2>/dev/null || true ;;
    esac
  done || true

  # 删除顶层目录标记并清理未完成分片
  mc rm --force "$PREFIX/" 2>/dev/null || true
  mc rm --incomplete --recursive --force "$PREFIX/" 2>/dev/null || true

  echo "✅ 已删除 $BUCKET/$TARGET_DIR/$TARGET_PATH/"
  exit 0
fi

case "${1:-}" in
  '') ;;
  -h|--help) usage ;;
  *) echo "❌ 未知参数: $1" >&2; usage ;;
esac

mc alias set "$ALIAS" "$ENDPOINT" "$ADMIN_AK" "$ADMIN_SK" >/dev/null

CUTOFF_DATE="$(date -d '7 days ago' +%Y%m%d)"

# copyin/<用户>/<日期>/
clean_copyin() {
  mc ls "$ALIAS/$BUCKET/copyin/" 2>/dev/null | awk '{print $NF}' | while read -r user_dir; do
    user="$(basename "$user_dir" | tr -d '/')"
    [ -n "$user" ] || continue

    mc ls "$ALIAS/$BUCKET/copyin/$user/" 2>/dev/null | awk '{print $NF}' | while read -r dir; do
      dir_date="$(basename "$dir" | tr -d '/')"

      case "$dir_date" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) continue ;;
      esac

      if [ "$dir_date" -lt "$CUTOFF_DATE" ]; then
        echo "删除过期目录: $BUCKET/copyin/$user/$dir_date/"
        mc rm --recursive --force "$ALIAS/$BUCKET/copyin/$user/$dir_date/"
      fi
    done || true
  done || true

  # 清理 copyin/ 下超过 7 天的未完成分片上传
  mc rm --incomplete --recursive --force --older-than 7d \
    "$ALIAS/$BUCKET/copyin/" 2>/dev/null || true
}

clean_copyin

echo "清理完成：copyin/ 下所有用户的过期目录与未完成分片"