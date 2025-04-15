#!/bin/bash

set -e

echo "🔧 开始一键安装 WireGuard + Hysteria2 (非Docker 版)"

WG_PORT=$(shuf -i 39500-39509 -n 1)
HYSTERIA_PORT=$(shuf -i 39510-39519 -n 1)
WG_INTERFACE="wg0"
WG_DIR="/etc/wireguard"
TLS_DIR="/etc/hysteria"
CONFIG_PATH="/etc/hysteria/config.yaml"
CLIENT_CONFIG_DIR="$HOME/guard/configs"
QRCODE_DIR="$HOME/guard/qrcode"

mkdir -p "$WG_DIR" "$TLS_DIR" "$CLIENT_CONFIG_DIR" "$QRCODE_DIR"

echo "[+] 安装依赖..."
apt update -y
apt install -y wireguard qrencode curl unzip jq iproute2 iptables dnsutils

echo "[+] 开启 IPv4 转发..."
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wg.conf
sysctl --system > /dev/null

echo "[+] 安装 Hysteria2 (非 Docker)..."
bash <(curl -fsSL https://get.hy2.sh/)

echo "[+] 创建 WireGuard 密钥对..."
[[ -f "$WG_DIR/private.key" ]] || wg genkey | tee "$WG_DIR/private.key" | wg pubkey > "$WG_DIR/public.key"

PRIVATE_KEY=$(cat "$WG_DIR/private.key")
PUBLIC_KEY=$(cat "$WG_DIR/public.key")

echo "[+] 写入 WireGuard 配置..."
cat > "$WG_DIR/$WG_INTERFACE.conf" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.66.66.1/24
ListenPort = $WG_PORT
MTU = 1420
PostUp = iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = xxx-client-key
AllowedIPs = 10.66.66.2/32
EOF

echo "[+] 启动 WireGuard 接口..."
ip link show $WG_INTERFACE &>/dev/null && wg-quick down $WG_INTERFACE
systemctl enable wg-quick@$WG_INTERFACE
systemctl start wg-quick@$WG_INTERFACE

echo "[+] 生成自签 TLS 证书..."
openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
  -keyout "$TLS_DIR/key.pem" -out "$TLS_DIR/cert.pem" -days 3650 \
  -subj "/CN=hy2.local"

echo "[+] 生成 Hysteria2 配置..."
cat > "$CONFIG_PATH" <<EOF
listen: :$HYSTERIA_PORT

tls:
  cert: $TLS_DIR/cert.pem
  key: $TLS_DIR/key.pem

auth:
  type: disabled

forward:
  type: wireguard
  server: 127.0.0.1:$WG_PORT
  localAddress: 10.66.66.2/32
  privateKey: $PRIVATE_KEY
EOF

echo "[+] 创建 Hysteria2 systemd 服务..."
cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria Server Service (config.yaml)
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server --config $CONFIG_PATH
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable hysteria-server
systemctl restart hysteria-server

echo "[+] 获取 Telegram / Signal / YouTube IP..."
SPLIT_IPS="$CLIENT_CONFIG_DIR/split_ips.txt"
> "$SPLIT_IPS"

for domain in telegram.org signal.org youtube.com; do
  dig +short $domain | grep -Eo '([0-9.]+)' | sed 's/$/\/32/' >> "$SPLIT_IPS"
done

echo "[+] 生成客户端配置文件..."
cat > "$CLIENT_CONFIG_DIR/wg-global.conf" <<EOF
[Interface]
PrivateKey = xxx-client-private-key
Address = 10.66.66.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $PUBLIC_KEY
Endpoint = your_domain_or_ip:$HYSTERIA_PORT
AllowedIPs = 0.0.0.0/0
EOF

cat > "$CLIENT_CONFIG_DIR/wg-split.conf" <<EOF
[Interface]
PrivateKey = xxx-client-private-key
Address = 10.66.66.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $PUBLIC_KEY
Endpoint = your_domain_or_ip:$HYSTERIA_PORT
AllowedIPs = $(paste -sd, $SPLIT_IPS)
EOF

echo "[+] 生成二维码..."
qrencode -o "$QRCODE_DIR/qr-global.png" < "$CLIENT_CONFIG_DIR/wg-global.conf"
qrencode -o "$QRCODE_DIR/qr-split.png" < "$CLIENT_CONFIG_DIR/wg-split.conf"

echo "[+] 打包客户端配置..."
zip -j "$CLIENT_CONFIG_DIR/client-configs.zip" "$CLIENT_CONFIG_DIR"/*.conf "$QRCODE_DIR"/*.png

echo "✅ 安装完成！"
echo "📁 配置文件目录: $CLIENT_CONFIG_DIR"
echo "📱 二维码文件：$QRCODE_DIR"
echo "🚀 建议运行诊断脚本确认状态："
echo ""
echo "   bash <(curl -fsSL https://raw.githubusercontent.com/sdkeio32/WireGuard_One-click_script_building_and_manual_script_building_Universal_version/main/diagnose.sh)"
