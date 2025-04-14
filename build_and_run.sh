#!/bin/bash

GUARD_DIR="/root/guard"
CONTAINER_NAME="guards"
IMAGE_NAME="wireguard-guard"

echo "[+] 移除旧容器（如存在）..."
docker rm -f $CONTAINER_NAME 2>/dev/null

echo "[+] 创建必要目录..."
mkdir -p "$GUARD_DIR/export" "$GUARD_DIR/config/split_ips"

echo "[+] 开始构建镜像（使用最新 Dockerfile）..."
docker build --no-cache -t $IMAGE_NAME "$GUARD_DIR"

echo "[+] 启动容器 $CONTAINER_NAME..."
docker run -d \
  --name $CONTAINER_NAME \
  --cap-add=NET_ADMIN \
  --network=host \
  -v "$GUARD_DIR":/root/guard \
  --restart always \
  $IMAGE_NAME

echo "[+] 构建完成！使用 'docker ps' 查看运行状态。"
