#!/bin/bash

set -e

IMAGE=vscode:latest

HOST_USER=$(whoami)
HOST_UID=$(id -u)
HOST_GID=$(id -g)

echo "[run] user=$HOST_USER uid=$HOST_UID gid=$HOST_GID"

xhost +local:docker

mkdir -p $HOME/workspace
mkdir -p $HOME/.vscode

sudo /bin/docker run --rm -it \
  --name devtools \
  --shm-size="1gb" \
  -e DISPLAY=$DISPLAY \
  -e HOST_UID=$HOST_UID \
  -e HOST_GID=$HOST_GID \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v $HOME/workspace:/home/ubuntu/workspace \
  -v $HOME/.vscode:/home/ubuntu/.vscode \
  $IMAGE \
  bash -c ' 
    set -e

    eval "$(dbus-launch --sh-syntax)"
    fcitx5 -d
    code --no-sandbox \
        --user-data-dir=/home/ubuntu/.vscode \
        --ozone-platform=x11 \
        --disable-workspace-trust \
        --disable-gpu \
        --wait
  '
  #--password-store=basic \
  #--wait
  #--security-opt label=disable \
  #--tmpfs /run \
  #--tmpfs /tmp:rw,mode=1777  \
  #-e DBUS_SESSION_BUS_ADDRESS=SDBUS_SESSION_BUS_ADDRESS \
  #-e QT X11_NO_MITSHM=1
  #-v /run/user/$HOST_UID/bus:/run/user/$HOST_UID/bus \
  #-e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus \
