#!/bin/bash
set -e

# ========== 自动获取公网 IPv4 ==========
SERVER_IP=$(curl -s https://api.ipify.org)

# ========== 变量定义 ==========
WG_DIR="$HOME/guard/wireguard"
TOOL_DIR="$HOME/guard/tools"
QR_DIR="$HOME/guard/qrcode"
CONFIG_GEN="$HOME/guard/configs"
HYSTERIA_PORT_START=39511
HYSTERIA_PORT_END=39520
WG_PORT_START=39500
WG_PORT_END=39510
WG_IFACE="wg0"

mkdir -p "$WG_DIR" "$TOOL_DIR" "$QR_DIR" "$CONFIG_GEN"

echo "[+] 安装基本依赖..."
sudo apt update
sudo apt install -y wireguard qrencode curl unzip iptables iproute2 jq lsb-release ca-certificates gnupg dnsutils

# ========== Docker 安装 ==========
echo "[+] 安装 Docker..."
sudo apt remove -y docker docker-engine docker.io containerd runc || true
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin

# ========== WireGuard 密钥生成 ==========
cd "$WG_DIR"
wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key

SERVER_PRIV_KEY=$(cat server_private.key)
SERVER_PUB_KEY=$(cat server_public.key)
CLIENT_PRIV_KEY=$(cat client_private.key)
CLIENT_PUB_KEY=$(cat client_public.key)

# ========== 随机端口 ==========
WG_PORT=$(shuf -i ${WG_PORT_START}-${WG_PORT_END} -n 1)
HYSTERIA_PORT=$(shuf -i ${HYSTERIA_PORT_START}-${HYSTERIA_PORT_END} -n 1)

echo "[+] WireGuard 端口: $WG_PORT"
echo "[+] Hysteria2 端口: $HYSTERIA_PORT"

# ========== 启用 IPv4 转发 ==========
echo "[+] 启用 IPv4 转发..."
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# ========== WireGuard 配置 ==========
cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = $SERVER_PRIV_KEY
Address = 10.10.0.1/24
ListenPort = $WG_PORT
PostUp = iptables -A FORWARD -i $WG_IFACE -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_IFACE -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB_KEY
AllowedIPs = 10.10.0.2/32
EOF

sudo wg-quick down "$WG_IFACE" 2>/dev/null || true
sudo wg-quick up "$WG_IFACE"

# ========== TLS 自签证书 ==========
echo "[+] 生成自签 TLS 证书..."
mkdir -p "$TOOL_DIR/tls"
openssl req -x509 -newkey rsa:2048 -keyout "$TOOL_DIR/tls/key.pem" -out "$TOOL_DIR/tls/cert.pem" -days 365 -nodes -subj "/CN=spotify.com"

# ========== Hysteria2 配置 ==========
echo "[+] 部署 Hysteria2..."
cat > "$TOOL_DIR/hysteria2-config.yaml" <<EOF
listen: :$HYSTERIA_PORT
tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem
auth:
  type: disabled
forward:
  type: wireguard
  server: 127.0.0.1:$WG_PORT
  password: ""
EOF

docker stop hysteria2 2>/dev/null || true
docker rm hysteria2 2>/dev/null || true
docker run -d --name hysteria2 \
  -v "$TOOL_DIR/tls:/etc/hysteria" \
  -v "$TOOL_DIR/hysteria2-config.yaml:/etc/hysteria/config.yaml" \
  -p $HYSTERIA_PORT:$HYSTERIA_PORT/udp \
  tobyxdd/hysteria server --config /etc/hysteria/config.yaml

# ========== 拉取 Telegram / Signal / YouTube IP ==========
echo "[+] 获取分流目标 IP..."
curl -s https://core.telegram.org/resources/cidr.txt | grep -Eo '([0-9.]+/..?)' > "$CONFIG_GEN/telegram.txt"
{
  dig +short signal.org
  dig +short www.signal.org
} | grep -Eo '([0-9.]+)' | sed 's/$/\/32/' | sort -u > "$CONFIG_GEN/signal.txt"
dig +short youtube.com | grep -Eo '([0-9.]+)' | sed 's/$/\/32/' > "$CONFIG_GEN/youtube.txt"

# 合并 IP 列表
cat "$CONFIG_GEN/telegram.txt" "$CONFIG_GEN/signal.txt" "$CONFIG_GEN/youtube.txt" > "$CONFIG_GEN/split_ips.tmp"
mv "$CONFIG_GEN/split_ips.tmp" "$CONFIG_GEN/split_ips.txt"

# ========== 客户端配置 ==========
echo "[+] 生成客户端配置文件..."
cat > "$CONFIG_GEN/wg-global.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV_KEY
Address = 10.10.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB_KEY
Endpoint = $SERVER_IP:$HYSTERIA_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

cat > "$CONFIG_GEN/wg-split.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV_KEY
Address = 10.10.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB_KEY
Endpoint = $SERVER_IP:$HYSTERIA_PORT
AllowedIPs = $(paste -sd "," "$CONFIG_GEN/split_ips.txt")
PersistentKeepalive = 120
EOF

# ========== 生成二维码 ==========
echo "[+] 生成二维码..."
qrencode -o "$QR_DIR/qr-global.png" < "$CONFIG_GEN/wg-global.conf"
qrencode -o "$QR_DIR/qr-split.png" < "$CONFIG_GEN/wg-split.conf"

# ========== 打包客户端配置 ==========
echo "[+] 打包客户端配置..."
cd "$CONFIG_GEN"
zip -r "$HOME/guard/client-configs.zip" wg-*.conf
cp "$QR_DIR"/*.png "$HOME/guard/"

echo -e "\n✅ 安装完成！"
echo "📄 客户端配置："
echo "   $CONFIG_GEN/wg-global.conf"
echo "   $CONFIG_GEN/wg-split.conf"
echo "📱 二维码文件："
echo "   $QR_DIR/qr-global.png"
echo "   $QR_DIR/qr-split.png"
echo "📦 打包配置 ZIP：$HOME/guard/client-configs.zip"
