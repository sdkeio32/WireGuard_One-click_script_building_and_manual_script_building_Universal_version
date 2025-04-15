#!/bin/bash

# 更新系统并安装必要依赖
echo "[+] 安装必要依赖..."
apt update && apt upgrade -y
apt install -y iproute2 jq qrencode wireguard curl iptables unzip dnsutils resolvconf gnupg ca-certificates lsb-release net-tools

# 启用 IPv4 转发
echo "[+] 启用 IPv4 转发..."
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

# 安装 Hysteria2 (非 Docker)
echo "[+] 安装 Hysteria2 (非 Docker)..."
HYSTERIA_VERSION="v2.6.1"
HYSTERIA_BIN="/usr/local/bin/hysteria"
HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
HYSTERIA_SERVICE="/etc/systemd/system/hysteria-server.service"

# 下载并安装 Hysteria
curl -L "https://github.com/apernet/hysteria/releases/download/app%2F${HYSTERIA_VERSION}/hysteria-linux-amd64" -o $HYSTERIA_BIN
chmod +x $HYSTERIA_BIN

# 创建 Hysteria 配置文件
echo "[+] 写入 Hysteria2 配置..."
cat > $HYSTERIA_CONFIG <<EOF
listen: :39656
forward:
  type: wireguard
  server: 127.0.0.1:39500
EOF

# 创建 Hysteria 服务文件
echo "[+] 创建 Hysteria2 systemd 服务..."
cat > $HYSTERIA_SERVICE <<EOF
[Unit]
Description=Hysteria Server Service (config.yaml)
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=on-failure
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

# 重新加载 systemd 配置
systemctl daemon-reexec

# 启动 Hysteria 服务
echo "[+] 启动 Hysteria2 服务..."
systemctl enable hysteria-server
systemctl start hysteria-server

# 配置 WireGuard
echo "[+] 配置 WireGuard..."

# 生成 WireGuard 密钥对
wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey

# 配置 WireGuard
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $(cat /etc/wireguard/privatekey)
Address = 10.66.66.1/24
ListenPort = 39500
MTU = 1420
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = xxx-client-key
AllowedIPs = 10.66.66.2/32
EOF

# 启动 WireGuard 接口
echo "[+] 启动 WireGuard 接口..."
wg-quick up wg0

# 打印配置信息
echo "[+] 安装完成！"
echo "  配置文件目录: /etc/hysteria/config.yaml"
echo "  配置完成！"

# 提示用户运行诊断脚本检查状态
echo "🚀 请运行以下命令检查状态："
echo "   bash <(curl -fsSL https://raw.githubusercontent.com/sdkeio32/WireGuard_One-click_script_building_and_manual_script_building_Universal_version/main/diagnose.sh)"
