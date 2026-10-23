#!/bin/bash

set -e

echo "[entrypoint] host: id=$HOST_UID gid=$HOST_GID"
echo "[entrypoint] container: user=$(whoami) home=$HOME uid=$(id -u) gid=$(id -g)"
echo "[entrypoint] PWD=$(pwd)"

CONTAINER_UID=1000
CONTAINER_GID=1000
CONTAINER_USER="ubuntu"
CONTAINER_GROUP="ubuntu"

if [ "$HOST_UID" != "$CONTAINER_UID" ] || [ "$HOST_GID" != "$CONTAINER_GID" ]; then
  echo "[entrypoint] change user: uid:1000->$HOST_UID, gid:1000->$HOST_GID"
  groupmod -g "$HOST_GID" "$CONTAINER_GROUP" 2>/dev/null || true
  usermod -u "$HOST_UID" "$CONTAINER_USER" 2>/dev/null || true
  chown -R "$HOST_UID:$HOST_GID" /home/ubuntu
fi

exec gosu $CONTAINER_USER "$@"
