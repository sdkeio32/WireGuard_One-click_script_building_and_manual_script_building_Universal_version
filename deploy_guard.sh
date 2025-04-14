#!/bin/bash

# 定义颜色输出
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}开始部署 WireGuard + Hysteria2 服务...${NC}"

# 创建基础目录结构
mkdir -p /guard/{docker,scripts,config/{wireguard,hysteria2},export/{full_proxy,split_routing}}

# 安装基础组件
apt update
apt install -y wireguard qrencode docker.io curl wget

# 下载并安装 Hysteria2
wget -O /guard/hysteria2 https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /guard/hysteria2

# 创建 Dockerfile
cat > /guard/docker/Dockerfile << 'EOF'
FROM ubuntu:22.04
RUN apt update && apt install -y wireguard qrencode iptables
COPY . /guard/
RUN chmod +x /guard/hysteria2
RUN chmod +x /guard/scripts/*
WORKDIR /guard
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
AllowedIPs = 149.154.160.0/20, 91.108.4.0/22, 91.108.56.0/22, 109.239.140.0/24, 172.217.0.0/16
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

# 构建和运行 Docker 容器
cd /guard
docker build -t guards_image .
docker run -d --name guards \
  --cap-add=NET_ADMIN \
  --network=host \
  --restart=always \
  guards_image

echo -e "${GREEN}部署完成！${NC}"
echo "全局代理二维码："
cat /guard/export/full_proxy/qr.txt
echo "分流代理二维码："
cat /guard/export/split_routing/qr.txt
