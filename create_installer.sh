#!/bin/bash

# 创建一键安装脚本
cat > /root/install_vpn.sh << 'EOF'
#!/bin/bash

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 检查root权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用root权限运行此脚本${PLAIN}"
    exit 1
fi

# 创建目录结构
echo -e "${GREEN}创建目录结构...${PLAIN}"
mkdir -p /guard/{bin,conf,scripts,qrcodes}

# 安装依赖
echo -e "${GREEN}安装依赖包...${PLAIN}"
apt update
apt install -y wireguard qrencode iptables curl wget git

# 下载udp2raw
echo -e "${GREEN}下载udp2raw...${PLAIN}"
cd /tmp
wget https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz
tar -xzvf udp2raw_binaries.tar.gz
cp udp2raw_amd64 /guard/bin/
chmod +x /guard/bin/udp2raw_amd64

# 生成WireGuard密钥
echo -e "${GREEN}生成WireGuard密钥...${PLAIN}"
wg genkey | tee /guard/conf/server_private.key | wg pubkey > /guard/conf/server_public.key
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

# 创建WireGuard配置
cat > /etc/wireguard/wg0.conf << WGCONF
[Interface]
PrivateKey = $(cat /guard/conf/server_private.key)
Address = 10.0.0.1/24
ListenPort = 39998
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = 10.0.0.2/32
WGCONF

# 创建udp2raw配置
cat > /guard/conf/udp2raw.conf << CONF
-s
-l 0.0.0.0:39500
-r 127.0.0.1:39998
-a
-k "vpn_password_$(date +%s)"
--raw-mode faketcp
--cipher-mode aes128cbc
--auth-mode hmac_sha1
CONF

# 创建动态端口脚本
cat > /guard/scripts/port_manager.sh << 'PORTSCRIPT'
#!/bin/bash
while true; do
    # 生成随机端口
    NEW_PORT=$(shuf -i 39501-39990 -n 1)
    # 更新udp2raw配置
    sed -i "s/-l 0.0.0.0:[0-9]*/-l 0.0.0.0:${NEW_PORT}/" /guard/conf/udp2raw.conf
    # 重启udp2raw服务
    systemctl restart udp2raw
    # 等待5分钟
    sleep 300
done
PORTSCRIPT
chmod +x /guard/scripts/port_manager.sh

# 创建客户端配置生成脚本
cat > /guard/scripts/generate_client.sh << 'GENSCRIPT'
#!/bin/bash
if [ $# -eq 1 ]; then
    CLIENT_PORT=$1
    if ! [[ "$CLIENT_PORT" =~ ^[0-9]+$ ]] || [ "$CLIENT_PORT" -lt 39501 ] || [ "$CLIENT_PORT" -gt 39990 ]; then
        echo "端口号必须在39501-39990之间"
        exit 1
    fi
else
    CLIENT_PORT=$(shuf -i 39501-39990 -n 1)
fi

SERVER_IP=$(curl -s ifconfig.me)
PASSWORD=$(grep -oP '(?<=-k ")[^"]*' /guard/conf/udp2raw.conf)

# 生成客户端配置
cat > /guard/conf/client_${CLIENT_PORT}.conf << CLIENTCONF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.0.0.2/24
DNS = 8.8.8.8

[Peer]
PublicKey = $(cat /guard/conf/server_public.key)
Endpoint = ${SERVER_IP}:${CLIENT_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLIENTCONF

# 生成udp2raw客户端配置
cat > /guard/conf/udp2raw_client_${CLIENT_PORT}.conf << RAWCONF
-c
-l 0.0.0.0:39998
-r ${SERVER_IP}:${CLIENT_PORT}
-k "${PASSWORD}"
--raw-mode faketcp
--cipher-mode aes128cbc
--auth-mode hmac_sha1
RAWCONF

# 生成二维码
qrencode -t PNG -o /guard/qrcodes/vpn_config_${CLIENT_PORT}.png < /guard/conf/client_${CLIENT_PORT}.conf

echo "配置文件已生成："
echo "WireGuard配置：/guard/conf/client_${CLIENT_PORT}.conf"
echo "udp2raw配置：/guard/conf/udp2raw_client_${CLIENT_PORT}.conf"
echo "二维码：/guard/qrcodes/vpn_config_${CLIENT_PORT}.png"
GENSCRIPT
chmod +x /guard/scripts/generate_client.sh

# 配置系统服务
cat > /etc/systemd/system/udp2raw.service << SERVICE
[Unit]
Description=udp2raw Service
After=network.target

[Service]
Type=simple
ExecStart=/guard/bin/udp2raw_amd64 --conf-file /guard/conf/udp2raw.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

cat > /etc/systemd/system/port_manager.service << SERVICE
[Unit]
Description=UDP2Raw Port Manager
After=network.target

[Service]
Type=simple
ExecStart=/guard/scripts/port_manager.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

# 配置防火墙规则
echo -e "${GREEN}配置防火墙规则...${PLAIN}"
ufw allow 22/tcp
ufw allow 39000:40000/tcp
ufw allow 39000:40000/udp

# 启用IP转发
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

# 启动服务
echo -e "${GREEN}启动服务...${PLAIN}"
systemctl daemon-reload
systemctl enable udp2raw
systemctl start udp2raw
systemctl enable port_manager
systemctl start port_manager
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# 克隆GitHub仓库
echo -e "${GREEN}克隆GitHub仓库...${PLAIN}"
cd /root
git clone https://github.com/sdkeio32/WireGuard_One-click_script_building_and_manual_script_building_Universal_version.git vpn_scripts

# 生成初始客户端配置
/guard/scripts/generate_client.sh

echo -e "${GREEN}安装完成！${PLAIN}"
echo -e "${YELLOW}使用以下命令生成新的客户端配置：${PLAIN}"
echo -e "${GREEN}/guard/scripts/generate_client.sh [端口号]${PLAIN}"
echo -e "${YELLOW}端口号可选，不指定则随机生成${PLAIN}"
EOF

chmod +x /root/install_vpn.sh
