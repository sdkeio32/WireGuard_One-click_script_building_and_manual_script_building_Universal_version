#!/bin/bash
set -e

echo -e "\n🔧 开始一键安装 WireGuard + Hysteria2 (非Docker 版)"

# ----------------------------
# 函数：检测并安装依赖
# ----------------------------
check_and_install() {
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            echo "[+] 安装缺失依赖：$pkg"
            apt install -y "$pkg" >/dev/null
        else
            echo "[√] 依赖已安装：$pkg"
        fi
    done
}

# ----------------------------
# 基本依赖
# ----------------------------
echo -e "\n[+] 检查并安装必要依赖..."
apt update -y >/dev/null
check_and_install \
    iproute2 \
    jq \
    qrencode \
    wireguard \
    curl \
    iptables \
    unzip \
    dnsutils \
    resolvconf \
    gnupg \
    ca-certificates \
    lsb-release \
    net-tools

# ----------------------------
# 启用 IPv4 转发
# ----------------------------
echo -e "\n[+] 启用 IPv4 转发..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# ----------------------------
# 安装 Hysteria2
# ----------------------------
echo -e "\n[+] 安装 Hysteria2 (非 Docker)..."
bash <(curl -fsSL https://get.hy2.sh/)

# ----------------------------
# 准备目录
# ----------------------------
WG_CONF_DIR="/etc/wireguard"
mkdir -p "$WG_CONF_DIR"
mkdir -p /root/guard/configs /root/guard/qrcode /etc/hysteria

# ----------------------------
# 生成密钥对
# ----------------------------
echo -e "\n[+] 创建 WireGuard 密钥对..."
server_private_key=$(wg genkey)
server_public_key=$(echo "$server_private_key" | wg pubkey)

client_private_key=$(wg genkey)
client_public_key=$(echo "$client_private_key" | wg pubkey)

# ----------------------------
# 随机端口
# ----------------------------
WG_PORT=$((RANDOM % 1000 + 39500))
HYST_PORT=$((RANDOM % 1000 + 39510))

# ----------------------------
# 写入 WireGuard 配置
# ----------------------------
echo -e "\n[+] 写入 WireGuard 配置..."
cat > "$WG_CONF_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = $server_private_key
Address = 10.66.66.1/24
ListenPort = $WG_PORT
MTU = 1420
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = $client_public_key
AllowedIPs = 10.66.66.2/32
EOF

# ----------------------------
# 启动 wg0 接口
# ----------------------------
echo -e "\n[+] 启动 WireGuard 接口..."
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0

# ----------------------------
# 自签 TLS
# ----------------------------
echo -e "\n[+] 生成自签 TLS 证书..."
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout /etc/hysteria/key.pem \
  -out /etc/hysteria/cert.pem \
  -subj "/CN=$(hostname)" >/dev/null 2>&1

# ----------------------------
# Hysteria2 配置
# ----------------------------
echo -e "\n[+] 写入 Hysteria2 配置..."
cat > /etc/hysteria/config.yaml <<EOF
listen: :$HYST_PORT

tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem

auth:
  type: disabled

forward:
  type: wireguard
  server: 127.0.0.1:$WG_PORT
EOF

# ----------------------------
# 创建 systemd 服务
# ----------------------------
echo -e "\n[+] 创建 Hysteria2 systemd 服务..."
cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria Server Service (config.yaml)
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=on-failure
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# ----------------------------
# 写入客户端配置文件
# ----------------------------
echo -e "\n[+] 生成客户端配置文件..."
server_ip=$(curl -s https://api.ipify.org)
cat > /root/guard/configs/wg-global.conf <<EOF
[Interface]
PrivateKey = $client_private_key
Address = 10.66.66.2/24
DNS = 8.8.8.8

[Peer]
PublicKey = $server_public_key
Endpoint = $server_ip:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

cp /root/guard/configs/wg-global.conf /root/guard/configs/wg-split.conf

# ----------------------------
# 生成二维码
# ----------------------------
echo -e "\n[+] 生成二维码..."
qrencode -o /root/guard/qrcode/qr-global.png -t png < /root/guard/configs/wg-global.conf
qrencode -o /root/guard/qrcode/qr-split.png -t png < /root/guard/configs/wg-split.conf

# ----------------------------
# 打包配置
# ----------------------------
echo -e "\n[+] 打包客户端配置..."
zip -j /root/guard/client-configs.zip /root/guard/configs/wg-*.conf /root/guard/qrcode/*.png >/dev/null

# ----------------------------
# 结束提示
# ----------------------------
echo ""
echo "✅ 安装完成！"
echo "📁 配置文件目录: /root/guard/configs"
echo "📱 二维码文件：/root/guard/qrcode"
echo "📦 客户端 ZIP: /root/guard/client-configs.zip"
echo ""
echo "🚀 建议运行诊断脚本确认状态："
echo ""
echo "   bash <(curl -fsSL https://raw.githubusercontent.com/sdkeio32/WireGuard_One-click_script_building_and_manual_script_building_Universal_version/main/diagnose.sh)"
