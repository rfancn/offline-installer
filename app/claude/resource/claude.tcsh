#!/bin/bash

set -e

IMAGE=claude:latest
ANTHROPIC_AUTH_TOKEN=123456
ANTHROPIC_BASE_URL=http://127.0.0.1:8000/v1
ANTHROPIC_MODEL=qwen3.6

PROJECT_DIR=$(pwd)
HOST_USER=$(whoami)
HOST_UID=$(id -u)
HOST_GID=$(id -g)
NAME=claude_$HOST_USER

echo "[run] user=$HOST_USER uid=$HOST_UID gid=$HOST_GID project_dir=$PROJECT_DIR"

mkdir -p $HOME/.claude
mkdir -p $HOME/workspace

# 定义清理函数，用于处理退出逻辑
cleanup() {
  echo ""
  echo "⚠️  收到退出信号，正在停止..."
  # docker run 带有 --rm 参数，容器停止后会自动删除，无需手动 docker rm
  # 如果需要额外清理操作（如删除日志、临时文件），可以在这里添加
}

# 捕获 SIGINT (Ctrl+C) 和 SIGTERM (终止) 信号
trap cleanup SIGINT SIGTERM

sudo /bin/docker run --rm -it \
  --name $NAME \
  -e HOST_UID=$HOST_UID \
  -e HOST_GID=$HOST_GID \
  -v $HOME/.tcshrc:/home/ubuntu/.tcshrc \
  -v $HOME/.claude:/home/ubuntu/.claude \
  -v $PROJECT_DIR:/home/ubuntu/workspace \
  $IMAGE \
  tcsh -i -c '
    mkdir -p /home/ubuntu/.claude

    if ( ! -f "/home/ubuntu/.claude/settings.json" || ! -w "/home/ubuntu/.claude/settings.json" ) then
        cat > /home/ubuntu/.claude/settings.json << EOF
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "'"$ANTHROPIC_AUTH_TOKEN"'",
    "ANTHROPIC_BASE_URL": "'"$ANTHROPIC_BASE_URL"'",
    "ANTHROPIC_MODEL": "'"$ANTHROPIC_MODEL"'"
  }
}
EOF
    else
        cat > /home/ubuntu/.claude/settings.json << EOF
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "'"$ANTHROPIC_AUTH_TOKEN"'",
    "ANTHROPIC_BASE_URL": "'"$ANTHROPIC_BASE_URL"'",
    "ANTHROPIC_MODEL": "'"$ANTHROPIC_MODEL"'"
  }
}
EOF
    endif

    exec claude
  '

#  脚本退出时的额外清理
# 当 docker run 命令结束时（无论是正常退出还是被 trap 中断），都会执行到这里
echo "claude已停止。"
