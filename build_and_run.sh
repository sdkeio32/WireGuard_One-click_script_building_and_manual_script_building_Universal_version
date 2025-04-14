#!/bin/bash

GUARD_DIR="/root/guard"
CONTAINER_NAME="guards"

# 创建目录
mkdir -p "$GUARD_DIR/export" "$GUARD_DIR/config/split_ips"

# 构建 Docker 镜像
docker build -t wireguard-guard "$GUARD_DIR"

# 运行容器
docker run -d \
  --name $CONTAINER_NAME \
  --cap-add=NET_ADMIN \
  --network=host \
  -v "$GUARD_DIR":/root/guard \
  --restart always \
  wireguard-guard
