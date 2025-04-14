#!/bin/bash

# 定义颜色输出
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}开始部署 WireGuard + Hysteria2 服务...${NC}"

# 创建基础目录结构
mkdir -p /guard/{scripts,config/{wireguard,hysteria2},export/{full_proxy,split_routing}}

# 安装基础组件
echo -e "${GREEN}安装基础组件...${NC}"
apt update
apt install -y wireguard qrencode curl wget

# 下载并安装 Hysteria2
echo -e "${GREEN}下载 Hysteria2...${NC}"
wget -O /guard/hysteria2 https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /guard/hysteria2

# 创建启动脚本
cat > /guard/scripts/start.sh << 'EOF'
#!/bin/bash
PORT=$(shuf -i 39500-39900 -n 1)
wg-quick up wg0
/guard/hysteria2 server -c /guard/config/hysteria2/config.json
EOF

# 创建配置生成脚本
cat > /guard/scripts/generate_configs.sh << 'EOF'
#!/bin/bash
SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
PORT=$(shuf -i 39500-39900 -n 1)
SERVER_IP=$(curl -s ifconfig.me)

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
Endpoint = ${SERVER_IP}:${PORT}
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
Endpoint = ${SERVER_IP}:${PORT}
PersistentKeepalive = 25
WGEOF

# 生成全局代理二维码
echo -n "wg://$(base64 -w 0 < /guard/export/full_proxy/client.conf)" | qrencode -t ansiutf8 > /guard/export/full_proxy/qr.txt

# 生成分流代理二维码
echo -n "wg://$(base64 -w 0 < /guard/export/split_routing/client.conf)" | qrencode -t ansiutf8 > /guard/export/split_routing/qr.txt

# 同时生成配置文件的二维码（直接配置内容）
qrencode -t ansiutf8 < /guard/export/full_proxy/client.conf > /guard/export/full_proxy/qr_direct.txt
qrencode -t ansiutf8 < /guard/export/split_routing/client.conf > /guard/export/split_routing/qr_direct.txt
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

# 生成初始配置
echo -e "${GREEN}生成初始配置...${NC}"
/guard/scripts/generate_configs.sh

# 启动服务
echo -e "${GREEN}启动服务...${NC}"
/guard/scripts/start.sh

echo -e "${GREEN}部署完成！${NC}"
echo -e "${GREEN}全局代理二维码（方式1 - wg://格式）：${NC}"
cat /guard/export/full_proxy/qr.txt
echo -e "${GREEN}全局代理二维码（方式2 - 直接配置）：${NC}"
cat /guard/export/full_proxy/qr_direct.txt
echo -e "${GREEN}分流代理二维码（方式1 - wg://格式）：${NC}"
cat /guard/export/split_routing/qr.txt
echo -e "${GREEN}分流代理二维码（方式2 - 直接配置）：${NC}"
cat /guard/export/split_routing/qr_direct.txt
echo -e "${GREEN}配置文件位置：${NC}"
echo "全局代理配置：/guard/export/full_proxy/client.conf"
echo "分流代理配置：/guard/export/split_routing/client.conf"
