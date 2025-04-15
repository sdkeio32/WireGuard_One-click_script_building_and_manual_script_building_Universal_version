#!/bin/bash
set -e

WG_DIR="$HOME/guard/wireguard"
TOOL_DIR="$HOME/guard/tools"
CONFIG_DIR="$HOME/guard/configs"
QR_DIR="$HOME/guard/qrcode"
SERVER_IP=$(curl -s https://api.ipify.org)
WG_PORT=$(shuf -i 39500-39510 -n 1)
HYS_PORT=$(shuf -i 39511-39520 -n 1)
WG_IFACE="wg0"

mkdir -p "$WG_DIR" "$TOOL_DIR" "$CONFIG_DIR" "$QR_DIR"

echo "[+] 安装依赖..."
apt update && apt install -y wireguard qrencode curl iptables unzip jq dnsutils

echo "[+] 开启 IPv4 转发..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf
sysctl -p /etc/sysctl.d/99-forward.conf

echo "[+] 安装 Hysteria2（非 Docker）..."
bash <(curl -fsSL https://get.hy2.sh/)

echo "[+] 生成 WireGuard 密钥对..."
wg genkey | tee "$WG_DIR/server.key" | wg pubkey > "$WG_DIR/server.pub"
wg genkey | tee "$WG_DIR/client.key" | wg pubkey > "$WG_DIR/client.pub"

SERVER_PRIV=$(cat "$WG_DIR/server.key")
SERVER_PUB=$(cat "$WG_DIR/server.pub")
CLIENT_PRIV=$(cat "$WG_DIR/client.key")
CLIENT_PUB=$(cat "$WG_DIR/client.pub")

DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}')

echo "[+] 配置 WireGuard..."
cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = 10.66.66.1/24
ListenPort = $WG_PORT
PostUp = iptables -A FORWARD -i $WG_IFACE -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o $DEFAULT_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_IFACE -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o $DEFAULT_IFACE -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.66.66.2/32
EOF

echo "[+] 启动 WireGuard 接口..."
cp "$WG_DIR/wg0.conf" /etc/wireguard/wg0.conf
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "[+] 生成自签 TLS 证书..."
mkdir -p /etc/hysteria
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout /etc/hysteria/key.pem \
  -out /etc/hysteria/cert.pem \
  -subj "/CN=spotify.com"

echo "[+] 生成 Hysteria2 配置..."
cat > /etc/hysteria/config.yaml <<EOF
listen: :$HYS_PORT
tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem
auth:
  mode: disabled
forward:
  type: wireguard
  server: 127.0.0.1:$WG_PORT
  password: ""
EOF

echo "[+] 启动 Hysteria2..."
systemctl restart hysteria-server
systemctl enable hysteria-server

echo "[+] 获取 Telegram / Signal / YouTube 分流 IP..."
curl -s https://core.telegram.org/resources/cidr.txt | grep -Eo '[0-9.]+/[0-9]+' > "$CONFIG_DIR/telegram.txt"
{
  dig +short signal.org
  dig +short www.signal.org
} | grep -Eo '([0-9.]+)' | sed 's/$/\/32/' > "$CONFIG_DIR/signal.txt"
dig +short youtube.com | grep -Eo '([0-9.]+)' | sed 's/$/\/32/' > "$CONFIG_DIR/youtube.txt"

cat "$CONFIG_DIR/"*.txt > "$CONFIG_DIR/split_ips.txt"

echo "[+] 生成客户端配置文件..."
cat > "$CONFIG_DIR/wg-global.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.66.66.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:$HYS_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

cat > "$CONFIG_DIR/wg-split.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.66.66.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:$HYS_PORT
AllowedIPs = $(paste -sd "," "$CONFIG_DIR/split_ips.txt")
PersistentKeepalive = 25
EOF

qrencode -o "$QR_DIR/qr-global.png" < "$CONFIG_DIR/wg-global.conf"
qrencode -o "$QR_DIR/qr-split.png" < "$CONFIG_DIR/wg-split.conf"

cd "$CONFIG_DIR"
zip -r "$HOME/guard/client-configs.zip" wg-*.conf

echo -e "\n✅ 安装完成！"
echo "📄 配置文件路径："
echo "   $CONFIG_DIR/wg-global.conf"
echo "   $CONFIG_DIR/wg-split.conf"
echo "📱 二维码："
echo "   $QR_DIR/qr-global.png"
echo "   $QR_DIR/qr-split.png"
echo "📦 打包 zip：$HOME/guard/client-configs.zip"
