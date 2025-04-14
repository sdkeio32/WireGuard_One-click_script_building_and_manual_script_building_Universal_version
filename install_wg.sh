#!/bin/bash
set -e

# ========== 变量定义 ==========
WG_DIR="$HOME/guard/wireguard"
TOOL_DIR="$HOME/guard/tools"
QR_DIR="$HOME/guard/qrcode"
CONFIG_GEN="$HOME/guard/configs"
HYSTERIA_PORT_START=39511
HYSTERIA_PORT_END=39520
WG_PORT_START=39500
WG_PORT_END=39510
SERVER_IP="103.106.228.55"
PRIVATE_SUBNET="10.10.0.0/24"
DOCKER_IMAGE="tobyxdd/hysteria"
WG_IFACE="wg0"

# 创建目录结构
mkdir -p "$WG_DIR" "$TOOL_DIR" "$QR_DIR" "$CONFIG_GEN"

echo "[+] 安装依赖..."
sudo apt update
sudo apt install -y wireguard qrencode curl unzip iptables iproute2 lsb-release ca-certificates gnupg

# 修复 Docker 安装冲突方式
echo "[+] 修复 Docker 安装冲突，使用官方源..."
sudo apt remove -y docker docker-engine docker.io containerd runc || true
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# ========== 生成密钥 ==========
echo "[+] 生成 WireGuard 密钥对..."
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

# ========== WireGuard 服务端配置 ==========
echo "[+] 创建 WireGuard 配置..."
cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = $SERVER_PRIV_KEY
Address = 10.10.0.1/24
ListenPort = $WG_PORT
PostUp = iptables -A FORWARD -i $WG_IFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_IFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB_KEY
AllowedIPs = 10.10.0.2/32
EOF

sudo wg-quick down "$WG_IFACE" 2>/dev/null || true
sudo wg-quick up "$WG_DIR/wg0.conf"

# ========== TLS 自签证书 ==========
echo "[+] 生成自签TLS证书..."
mkdir -p "$TOOL_DIR/tls"
openssl req -x509 -newkey rsa:2048 -keyout "$TOOL_DIR/tls/key.pem" -out "$TOOL_DIR/tls/cert.pem" -days 365 -nodes -subj "/CN=spotify.com"

# ========== 部署 Hysteria2 ==========
echo "[+] 启动 Hysteria2 容器..."
cat > "$TOOL_DIR/hysteria2-config.yaml" <<EOF
listen: :$HYSTERIA_PORT
tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem
obfs:
  type: tls
  host: open.spotify.com
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
  $DOCKER_IMAGE server --config /etc/hysteria/config.yaml

# ========== 分流 IP 抓取 ==========
echo "[+] 获取分流 IP：Telegram / Signal / YouTube..."
curl -s https://core.telegram.org/resources/cidr.txt | grep -Eo '([0-9.]+/..?)' > "$CONFIG_GEN/telegram.txt"
curl -s https://signal.org/.well-known/relayinfo.json | jq -r '.relays[].ipv4' | sed 's/$/\/32/' > "$CONFIG_GEN/signal.txt"
dig +short youtube.com | grep -Eo '([0-9.]+)' | sed 's/$/\/32/' > "$CONFIG_GEN/youtube.txt"

cat "$CONFIG_GEN/"*.txt > "$CONFIG_GEN/split_ips.txt"

# ========== 生成客户端配置 ==========
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
PersistentKeepalive = 25
EOF

# ========== 二维码生成 ==========
echo "[+] 生成二维码..."
qrencode -o "$QR_DIR/qr-global.png" < "$CONFIG_GEN/wg-global.conf"
qrencode -o "$QR_DIR/qr-split.png" < "$CONFIG_GEN/wg-split.conf"

# ========== ZIP 打包 ==========
echo "[+] 打包配置..."
cd "$CONFIG_GEN"
zip -r "$HOME/guard/client-configs.zip" wg-*.conf
cp "$QR_DIR"/*.png "$HOME/guard/"

echo -e "\n✅ 安装成功！以下文件已生成："
echo "🔹 全局配置二维码: $QR_DIR/qr-global.png"
echo "🔹 分流配置二维码: $QR_DIR/qr-split.png"
echo "📦 客户端配置打包: $HOME/guard/client-configs.zip"
