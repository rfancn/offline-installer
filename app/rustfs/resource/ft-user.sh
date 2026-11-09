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

# 用户与策略管理使用 root 凭据（需要 admin 权限）
ROOT_AK="${RUSTFS_ACCESS_KEY:?请设置 RUSTFS_ACCESS_KEY}"
ROOT_SK="${RUSTFS_SECRET_KEY:?请设置 RUSTFS_SECRET_KEY}"

USER_GROUP="${RUSTFS_FT_USER_GROUP:-ft-user-group}"
USER_POLICY="${RUSTFS_FT_USER_POLICY:-ft-user-policy}"
BUCKET=file-transfer

usage() {
  cat <<'EOF'
用法:
  ft-user.sh add <用户名>            添加终端用户
  ft-user.sh del <用户名> [--yes]    删除终端用户及其 copyin/<用户名>/ 数据
EOF
  exit 1
}

if [ $# -lt 2 ]; then
  usage
fi

ACTION="$1"
TARGET_USER="$2"
shift 2

ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift ;;
    *) echo "❌ 未知参数: $1" >&2; usage ;;
  esac
done

case "$TARGET_USER" in
  ''|*[!A-Za-z0-9_-]*)
    echo "❌ 用户名只能包含字母、数字、下划线和连字符" >&2
    exit 1 ;;
esac

case "$TARGET_USER" in
  ft-admin|ft-copy-out|root)
    echo "❌ 不允许操作管理账号: $TARGET_USER" >&2
    exit 1 ;;
esac

mc alias set "$ALIAS" "$ENDPOINT" "$ROOT_AK" "$ROOT_SK" >/dev/null

add_user() {
  if mc admin user info "$ALIAS" "$TARGET_USER" >/dev/null 2>&1; then
    echo "用户已存在: $TARGET_USER"
  else
    USER_SK="$(openssl rand -hex 4)"
    mc admin user add "$ALIAS" "$TARGET_USER" "$USER_SK"
    echo "已创建用户: $TARGET_USER"
    echo "  Access Key: $TARGET_USER"
    echo "  Secret Key: $USER_SK"
  fi

  # 在 copyin/ 下创建用户名目录（S3 中为零字节目录标记对象）
  mc mb "$ALIAS/$BUCKET/copyin/$TARGET_USER/" 2>/dev/null || true

  # 个人下载策略：资源写死用户名，Console 前端才能识别并显示下载按钮
  POLICY_NAME="ft-user-${TARGET_USER}-policy"
  POLICY_FILE="/tmp/${POLICY_NAME}.json"

  cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectAttributes",
        "s3:GetObjectTagging",
        "s3:GetObjectRetention",
        "s3:GetObjectLegalHold"
      ],
      "Resource": ["arn:aws:s3:::$BUCKET/copyin/$TARGET_USER/*"]
    }
  ]
}
EOF

  mc admin policy detach "$ALIAS" "$POLICY_NAME" --user "$TARGET_USER" 2>/dev/null || true
  mc admin policy rm "$ALIAS" "$POLICY_NAME" 2>/dev/null || true
  mc admin policy create "$ALIAS" "$POLICY_NAME" "$POLICY_FILE"
  mc admin policy attach "$ALIAS" "$POLICY_NAME" --user "$TARGET_USER"
  rm -f "$POLICY_FILE"

  # 加入终端用户组，获得列表与桶元数据权限；组随首个成员创建后绑定组策略
  mc admin group add "$ALIAS" "$USER_GROUP" "$TARGET_USER" 2>/dev/null || true
  mc admin policy attach "$ALIAS" "$USER_POLICY" --group "$USER_GROUP" 2>/dev/null || true

  echo "✅ $TARGET_USER 已加入 $USER_GROUP，并绑定个人下载策略 $POLICY_NAME"
}

del_user() {
  if ! mc admin user info "$ALIAS" "$TARGET_USER" >/dev/null 2>&1; then
    echo "用户不存在: $TARGET_USER"
  fi

  if [ "$ASSUME_YES" -ne 1 ]; then
    printf "⚠️ 将删除用户 %s 及 copyin/%s/ 下所有数据，不可恢复。输入 yes 继续: " \
      "$TARGET_USER" "$TARGET_USER"
    read -r confirm || { echo; echo "已取消"; exit 1; }
    [ "$confirm" = "yes" ] || { echo "已取消"; exit 1; }
  fi

  # 删除 copyin/<用户名>/ 下的已完成对象与未完成分片
  echo "删除数据: $BUCKET/copyin/$TARGET_USER/"
  mc rm --recursive --force "$ALIAS/$BUCKET/copyin/$TARGET_USER/" 2>/dev/null || true
  mc rm --incomplete --recursive --force "$ALIAS/$BUCKET/copyin/$TARGET_USER/" 2>/dev/null || true

  # 删除用户及其个人策略
  POLICY_NAME="ft-user-${TARGET_USER}-policy"
  mc admin policy detach "$ALIAS" "$POLICY_NAME" --user "$TARGET_USER" 2>/dev/null || true
  mc admin user rm "$ALIAS" "$TARGET_USER" 2>/dev/null || true
  mc admin policy rm "$ALIAS" "$POLICY_NAME" 2>/dev/null || true

  echo "✅ 已删除用户 $TARGET_USER、copyin/$TARGET_USER/ 数据及个人策略"
}

case "$ACTION" in
  add)      add_user ;;
  del|rm)   del_user ;;
  *)        usage ;;
esac