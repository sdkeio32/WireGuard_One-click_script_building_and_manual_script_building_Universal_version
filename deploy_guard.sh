#!/bin/bash

# 定义颜色输出
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}开始部署 WireGuard + Hysteria2 服务...${NC}"

# 创建基础目录结构
mkdir -p /guard/{scripts,config/{wireguard,hysteria2},export/{full_proxy,split_routing}}

# 修复 Docker 安装问题
echo -e "${GREEN}修复 Docker 安装...${NC}"
apt remove -y docker docker-engine docker.io containerd runc
apt update
apt install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt update
apt install -y docker-ce docker-ce-cli containerd.io

# 安装基础组件
echo -e "${GREEN}安装基础组件...${NC}"
apt update
apt install -y wireguard qrencode curl wget

# 下载并安装 Hysteria2
echo -e "${GREEN}下载 Hysteria2...${NC}"
wget -O /guard/hysteria2 https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /guard/hysteria2

# 创建 Dockerfile
echo -e "${GREEN}创建 Docker 配置...${NC}"
cat > /guard/Dockerfile << 'EOF'
FROM ubuntu:22.04
RUN apt update && apt install -y wireguard qrencode iptables curl
WORKDIR /guard
COPY . .
RUN chmod +x /guard/hysteria2
RUN chmod +x /guard/scripts/*
CMD ["/guard/scripts/start.sh"]
EOF

# 创建启动脚本
cat > /guard/scripts/start.sh << 'EOF'
#!/bin/bash
PORT=$(shuf -i 39500-39900 -n 1)
wg-quick up wg0
/guard/hysteria2 server -c /guard/config/hysteria2/config.json
EOF

# 创建 WireGuard 配置生成脚本
cat > /guard/scripts/generate_configs.sh << 'EOF'
#!/bin/bash
if ! command -v wg &> /dev/null; then
    apt update && apt install -y wireguard
fi
if ! command -v qrencode &> /dev/null; then
    apt update && apt install -y qrencode
fi

SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo $SERVER_PRIVATE_KEY | wg pubkey)
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo $CLIENT_PRIVATE_KEY | wg pubkey)
PORT=$(shuf -i 39500-39900 -n 1)

# 生成服务器配置
cat > /guard/config/wireguard/wg0.conf << WGEOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
Address = 10.66.66.1/24
ListenPort = ${PORT}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = 10.66.66.2/32
WGEOF

# 生成全局代理客户端配置
cat > /guard/export/full_proxy/client.conf << WGEOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.66.66.2/24
DNS = 8.8.8.8

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0
Endpoint = $(curl -s ifconfig.me):${PORT}
PersistentKeepalive = 25
WGEOF

# 生成分流代理客户端配置
cat > /guard/export/split_routing/client.conf << WGEOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.66.66.2/24
DNS = 8.8.8.8

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = 149.154.160.0/20,91.108.4.0/22,91.108.8.0/22,91.108.12.0/22,91.108.16.0/22,91.108.20.0/22,91.108.56.0/22,149.154.164.0/22,149.154.168.0/22,149.154.172.0/22,172.217.0.0/16,108.177.0.0/17,142.250.0.0/15,172.253.0.0/16,173.194.0.0/16,216.58.192.0/19,216.239.32.0/19,74.125.0.0/16,24.199.123.28/32,52.52.62.137/32,52.218.48.0/20,34.248.0.0/13,35.157.0.0/16,35.186.0.0/17,35.192.0.0/14,35.224.0.0/14,35.228.0.0/14
Endpoint = $(curl -s ifconfig.me):${PORT}
PersistentKeepalive = 25
WGEOF

# 生成二维码
qrencode -t ansiutf8 < /guard/export/full_proxy/client.conf > /guard/export/full_proxy/qr.txt
qrencode -t ansiutf8 < /guard/export/split_routing/client.conf > /guard/export/split_routing/qr.txt
EOF

# 创建 Hysteria2 配置
cat > /guard/config/hysteria2/config.json << EOF
{
  "listen": ":${PORT}",
  "acme": {
    "domains": [],
    "email": ""
  },
  "obfs": {
    "type": "salamander",
    "salamander": {
      "password": "spotify_$(head -c 8 /dev/urandom | base64)"
    }
  },
  "masquerade": {
    "type": "proxy",
    "proxy": {
      "url": "https://open.spotify.com/show/3YH7knkMYcRJnjOG7wXtRf",
      "rewriteHost": true
    }
  }
}
EOF

# 设置脚本权限
chmod +x /guard/scripts/generate_configs.sh
chmod +x /guard/scripts/start.sh

# 清理已存在的容器和镜像
echo -e "${GREEN}清理旧的 Docker 容器和镜像...${NC}"
docker stop guards 2>/dev/null || true
docker rm guards 2>/dev/null || true
docker rmi guards_image 2>/dev/null || true

# 生成初始配置
echo -e "${GREEN}生成初始配置...${NC}"
cd /guard
/guard/scripts/generate_configs.sh

# 构建和运行 Docker 容器
echo -e "${GREEN}构建和运行 Docker 容器...${NC}"
cd /guard
docker build -t guards_image .
docker run -d --name guards \
  --cap-add=NET_ADMIN \
  --network=host \
  --restart=always \
  -v /guard:/guard \
  guards_image

echo -e "${GREEN}部署完成！${NC}"
echo "全局代理二维码："
cat /guard/export/full_proxy/qr.txt
echo "分流代理二维码（仅 Telegram、Signal 和 YouTube）："
cat /guard/export/split_routing/qr.txt
echo -e "${GREEN}配置文件位置：${NC}"
echo "全局代理配置：/guard/export/full_proxy/client.conf"
echo "分流代理配置：/guard/export/split_routing/client.conf"

# 显示容器状态
echo -e "${GREEN}容器状态：${NC}"
docker ps | grep guards
