#!/bin/sh
set -eu

ALIAS="rustfs"

# 以下配置由 ft-init.sh 写入本脚本，不从 .env 读取
COPYOUT_ENDPOINT="http://localhost:9000"
COPYOUT_AK="ft-copy-out"
COPYOUT_SK=""

ENDPOINT="$COPYOUT_ENDPOINT"
ADMIN_AK="$COPYOUT_AK"
ADMIN_SK="${COPYOUT_SK:?请先运行 ft-init.sh 生成 ft-copy-out 凭据}"

BUCKET=file-transfer

usage() {
  echo "用法: $0 <本地文件或目录...>"
  echo "示例: $0 report.pdf data/ logs/*.log"
  exit 1
}

if [ $# -eq 0 ]; then
  usage
fi

mc alias set "$ALIAS" "$ENDPOINT" "$ADMIN_AK" "$ADMIN_SK"

USERNAME="$(whoami)"
if [ -z "$USERNAME" ]; then
  echo "错误：无法获取当前用户名" >&2
  exit 1
fi

# 清理 copyout/ 下超过 7 天的未完成分片上传，避免残留 part 占用空间
mc rm --incomplete --recursive --force --older-than 7d \
  "$ALIAS/$BUCKET/copyout/" 2>/dev/null || true

TODAY="$(date +%Y%m%d)"
DEST_PREFIX="$BUCKET/copyout/$TODAY/$USERNAME"

UPLOADED=0

for src in "$@"; do
  for item in $src; do
    [ -e "$item" ] || continue

    if [ -d "$item" ]; then
      # mc cp -r 对空目录会报 "Unable to guess the type of copy operation"
      if [ -z "$(find "$item" -type f -print -quit 2>/dev/null)" ]; then
        echo "跳过空目录: $item"
        continue
      fi
      base="$(basename "$item")"
      mc cp -r "$item/" "$ALIAS/$DEST_PREFIX/$base/"
      UPLOADED=1
    else
      mc cp "$item" "$ALIAS/$DEST_PREFIX/"
      UPLOADED=1
    fi
  done
done

if [ "$UPLOADED" -eq 1 ]; then
  echo "上传完成：$DEST_PREFIX/"
  echo "当前 copyout/$TODAY/$USERNAME/ 下的文件："
  mc ls --recursive "$ALIAS/$BUCKET/copyout/$TODAY/$USERNAME/"
else
  echo "未上传任何文件"
fi
