#!/bin/bash
# deploy_guard.sh
mkdir -p /guard
cd /guard

# 安装基础组件
apt update
apt install -y wireguard qrencode docker.io

# 配置端口范围
PORTS_RANGE="39500-39900"

# 配置Hysteria2
HYSTERIA2_CONFIG='{
    "listen": ":$PORT",
    "obfs": "spotify",
    "up_mbps": 100,
    "down_mbps": 100
}'

# WireGuard配置
WIREGUARD_CONFIG='[Interface]
Address = 10.66.66.1/24
ListenPort = $PORT
PrivateKey = $(wg genkey)
'
