#!/bin/sh
set -eu

# ========== 加载脚本同目录下的 .env ==========
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  . "$SCRIPT_DIR/.env"
  set +a
else
  echo "警告: 未找到 $SCRIPT_DIR/.env，将使用默认值" >&2
fi

ALIAS="rustfs"
ENDPOINT="${RUSTFS_ENDPOINT:-http://localhost:9000}"
ADMIN_AK="${RUSTFS_ACCESS_KEY:?请设置 RUSTFS_ACCESS_KEY（root 凭据）}"
ADMIN_SK="${RUSTFS_SECRET_KEY:?请设置 RUSTFS_SECRET_KEY（root 凭据）}"

BUCKET=file-transfer

# 桶管理员：桶内完全权限，仅不可删桶
FTADMIN_USER="${RUSTFS_FTADMIN_AK:-ft-admin}"
FTADMIN_GROUP=ft-admin-group
FTADMIN_POLICY=ft-admin-policy

# Console 终端用户组与默认用户：只读下载自己的 copyin/<用户名>/ 目录
FT_USER_GROUP=ft-user-group
FT_USER_POLICY=ft-user-policy

# 拷出操作员：上传到 copyout/，不能下载
COPYOUT_USER="${RUSTFS_COPYOUT_AK:-ft-copy-out}"
COPYOUT_POLICY=ft-copyout-policy

# 生成 8 位随机密码（十六进制，便于用户输入）
rand_secret() {
  openssl rand -hex 4
}

# 将键值写入同目录 .env（存在则替换，不存在则追加）
upsert_env() {
  local key="$1" value="$2" file="$SCRIPT_DIR/.env" tmp
  tmp="$(mktemp)"
  grep -v "^${key}=" "$file" 2>/dev/null > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
  chmod 600 "$file"
}

FTADMIN_SK="${RUSTFS_FTADMIN_SK:-$(rand_secret)}"
COPYOUT_SK="${RUSTFS_COPYOUT_SK:-}"

mc alias set "$ALIAS" "$ENDPOINT" "$ADMIN_AK" "$ADMIN_SK"

# 检查桶是否存在，不存在则创建
if mc ls "$ALIAS/$BUCKET" >/dev/null 2>&1; then
  echo "✅ 桶已存在: $BUCKET"
else
  echo "📦 创建桶: $BUCKET"
  mc mb "$ALIAS/$BUCKET"
fi

# 确保基础目录存在
for d in copyin copyout; do
  mc mb "$ALIAS/$BUCKET/$d/" 2>/dev/null || true
done

# ========== ft-admin：桶内完全权限，但不能删桶 ==========
cat > /tmp/ft-admin-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListAllMyBuckets"],
      "Resource": ["arn:aws:s3:::*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads",
        "s3:GetBucketPolicyStatus",
        "s3:GetBucketPolicy",
        "s3:GetBucketVersioning",
        "s3:GetBucketObjectLockConfiguration",
        "s3:GetBucketTagging",
        "s3:GetBucketAcl"
      ],
      "Resource": ["arn:aws:s3:::file-transfer"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
        "s3:GetObjectTagging",
        "s3:PutObjectTagging"
      ],
      "Resource": ["arn:aws:s3:::file-transfer/*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "admin:CreateUser",
        "admin:AddUserToGroup",
        "admin:GetUser",
        "admin:GetGroup",
        "admin:ListUsers",
        "admin:ListGroups",
        "admin:AttachUserOrGroupPolicy",
        "admin:ListUserPolicies"
      ],
      "Resource": ["arn:aws:s3:::*"]
    },
    {
      "Effect": "Deny",
      "Action": ["s3:DeleteBucket"],
      "Resource": ["arn:aws:s3:::file-transfer"]
    }
  ]
}
EOF

# ========== ft-user 组：Console 登录后只能浏览/下载自己的目录 ==========
cat > /tmp/ft-user-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListAllMyBuckets"],
      "Resource": ["arn:aws:s3:::*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:HeadBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketAcl",
        "s3:GetBucketPolicyStatus",
        "s3:GetBucketVersioning",
        "s3:GetBucketObjectLockConfiguration",
        "s3:GetBucketTagging"
      ],
      "Resource": ["arn:aws:s3:::file-transfer"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::file-transfer"],
      "Condition": {
        "StringLikeIfExists": {
          "s3:prefix": [
            "",
            "copyin/",
            "copyin/${aws:username}/",
            "copyin/${aws:username}/*"
          ]
        }
      }
    }
  ]
}
EOF


# ========== ft-copy-out：写入 copyout/，可列出上传结果，不能下载 ==========
cat > /tmp/ft-copyout-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::file-transfer/copyout/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:HeadBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::file-transfer"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::file-transfer"],
      "Condition": {
        "StringLikeIfExists": {
          "s3:prefix": ["", "copyout/", "copyout/*"]
        }
      }
    }
  ]
}
EOF

# ========== 策略内容会随脚本更新：先解除绑定并删除，随后重新创建 ==========
mc admin policy detach "$ALIAS" "$FTADMIN_POLICY" --group "$FTADMIN_GROUP" 2>/dev/null || true
mc admin policy detach "$ALIAS" "$FT_USER_POLICY" --group "$FT_USER_GROUP" 2>/dev/null || true
mc admin policy detach "$ALIAS" "$COPYOUT_POLICY" --user "$COPYOUT_USER" 2>/dev/null || true
for p in "$FTADMIN_POLICY" "$FT_USER_POLICY" "$COPYOUT_POLICY"; do
  mc admin policy rm "$ALIAS" "$p" 2>/dev/null || true
done

# ========== 创建策略 ==========
mc admin policy create "$ALIAS" "$FTADMIN_POLICY" /tmp/ft-admin-policy.json
mc admin policy create "$ALIAS" "$FT_USER_POLICY" /tmp/ft-user-policy.json
mc admin policy create "$ALIAS" "$COPYOUT_POLICY" /tmp/ft-copyout-policy.json

# ========== 创建用户：已存在则跳过，不重置密码 ==========
FTADMIN_CREATED=0
COPYOUT_CREATED=0

if mc admin user info "$ALIAS" "$FTADMIN_USER" >/dev/null 2>&1; then
  echo "✅ 用户已存在，跳过: $FTADMIN_USER"
else
  mc admin user add "$ALIAS" "$FTADMIN_USER" "$FTADMIN_SK"
  FTADMIN_CREATED=1
  echo "📦 已创建用户: $FTADMIN_USER"
fi

if mc admin user info "$ALIAS" "$COPYOUT_USER" >/dev/null 2>&1; then
  echo "✅ 用户已存在，跳过: $COPYOUT_USER"
  # 优先使用 .env 中的密码；没有再回退到 ft-copy-out.sh 中已有的值
  if [ -z "$COPYOUT_SK" ]; then
    COPYOUT_SCRIPT="$SCRIPT_DIR/ft-copy-out.sh"
    if [ -f "$COPYOUT_SCRIPT" ]; then
      COPYOUT_SK="$(sed -n 's/^COPYOUT_SK="\(.*\)"/\1/p' "$COPYOUT_SCRIPT" | head -n1)"
    fi
  fi
  if [ -z "$COPYOUT_SK" ]; then
    echo "⚠️ 无法确定 $COPYOUT_USER 的现有密码，请在 .env 中设置 RUSTFS_COPYOUT_SK" >&2
  fi
else
  COPYOUT_SK="$(rand_secret)"
  mc admin user add "$ALIAS" "$COPYOUT_USER" "$COPYOUT_SK"
  upsert_env RUSTFS_COPYOUT_SK "$COPYOUT_SK"
  COPYOUT_CREATED=1
  echo "📦 已创建用户: $COPYOUT_USER"
fi

# ========== 绑定权限（组与绑定保持幂等） ==========
mc admin group add "$ALIAS" "$FTADMIN_GROUP" "$FTADMIN_USER" 2>/dev/null || true
mc admin policy attach "$ALIAS" "$FTADMIN_POLICY" --group "$FTADMIN_GROUP"
mc admin policy attach "$ALIAS" "$COPYOUT_POLICY" --user "$COPYOUT_USER"

# 终端用户组由 ft-user.sh add 在创建首个用户时建立；已存在则绑定策略
if mc admin policy attach "$ALIAS" "$FT_USER_POLICY" --group "$FT_USER_GROUP" 2>/dev/null; then
  FT_USERS_ATTACHED=1
else
  FT_USERS_ATTACHED=0
fi

# 将 ft-copy-out 凭据写入 ft-copy-out.sh（该脚本不从 .env 读取凭据）
COPYOUT_SCRIPT="$SCRIPT_DIR/ft-copy-out.sh"
if [ -f "$COPYOUT_SCRIPT" ]; then
  if [ -n "$COPYOUT_SK" ]; then
    sed -i "s|^COPYOUT_ENDPOINT=.*|COPYOUT_ENDPOINT=\"$ENDPOINT\"|" "$COPYOUT_SCRIPT"
    sed -i "s|^COPYOUT_AK=.*|COPYOUT_AK=\"$COPYOUT_USER\"|" "$COPYOUT_SCRIPT"
    sed -i "s|^COPYOUT_SK=.*|COPYOUT_SK=\"$COPYOUT_SK\"|" "$COPYOUT_SCRIPT"
    echo "✅ 已更新 ft-copy-out.sh 凭据"
  else
    echo "⚠️ 无可用 ft-copy-out 密码，跳过凭据写入" >&2
  fi
else
  echo "⚠️ 未找到 $COPYOUT_SCRIPT，跳过凭据写入" >&2
fi


rm -f /tmp/ft-admin-policy.json /tmp/ft-user-policy.json /tmp/ft-copyout-policy.json

echo "=========================================="
echo "初始化完成"
echo "=========================================="
echo "ft-admin（桶 $BUCKET 完全权限，仅不可删桶；供文件上传/清理）:"
echo "  Access Key: $FTADMIN_USER"
if [ "$FTADMIN_CREATED" -eq 1 ]; then
  echo "  Secret Key: $FTADMIN_SK"
else
  echo "  用户已存在，密码未修改"
fi
echo ""
echo "ft-copy-out（仅 copyout/ 上传/列出，不可下载）:"
echo "  Access Key: $COPYOUT_USER"
if [ "$COPYOUT_CREATED" -eq 1 ]; then
  echo "  Secret Key: $COPYOUT_SK"
else
  echo "  用户已存在，密码未修改"
fi
echo ""
echo "$FT_USER_GROUP 组（Console 用户，仅能浏览/下载 copyin/<用户名>/）:"
if [ "$FT_USERS_ATTACHED" -eq 1 ]; then
  echo "  策略 $FT_USER_POLICY 已绑定。"
else
  echo "  组尚未创建。运行 ft-user.sh add <用户名> 添加首个终端用户时会自动创建并绑定。"
fi
echo "=========================================="