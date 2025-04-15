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
wget -q https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz -O udp2raw_binaries.tar.gz
tar -xzvf udp2raw_binaries.tar.gz udp2raw_amd64
cp udp2raw_amd64 /guard/bin/
chmod +x /guard/bin/udp2raw_amd64
rm -f /tmp/udp2raw_binaries.tar.gz /tmp/udp2raw_amd64 # 清理临时文件

# 生成WireGuard密钥
echo -e "${GREEN}生成WireGuard密钥...${PLAIN}"
wg genkey | tee /guard/conf/server_private.key | wg pubkey > /guard/conf/server_public.key
wg genkey | tee /guard/conf/client_private.key | wg pubkey > /guard/conf/client_public.key # 同时保存客户端私钥和公钥到文件

# 创建WireGuard配置
cat > /etc/wireguard/wg0.conf << WGCONF
[Interface]
PrivateKey = $(cat /guard/conf/server_private.key)
Address = 10.0.0.1/24
ListenPort = 39998
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
PublicKey = $(cat /guard/conf/client_public.key) # 从文件读取客户端公钥
AllowedIPs = 10.0.0.2/32
WGCONF

# 创建udp2raw配置
UDP2RAW_PASS="vpn_password_$(date +%s | sha256sum | head -c 16)" # 生成更随机的密码
echo -e "${GREEN}创建udp2raw配置...${PLAIN}"
cat > /guard/conf/udp2raw.conf << CONF
-s
-l 0.0.0.0:39500
-r 127.0.0.1:39998
-a
-k "${UDP2RAW_PASS}"
--raw-mode faketcp
--cipher-mode aes128cbc
--auth-mode hmac_sha1
CONF

# 创建客户端配置生成脚本
echo -e "${GREEN}创建客户端配置生成脚本...${PLAIN}"
cat > /guard/scripts/generate_client.sh << 'GENSCRIPT'
#!/bin/bash
# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

if [ ! -f /guard/conf/client_private.key ] || [ ! -f /guard/conf/server_public.key ] || [ ! -f /guard/conf/udp2raw.conf ]; then
    echo -e "${RED}错误：缺少必要的服务器配置文件！${PLAIN}"
    exit 1
fi

if [ $# -eq 1 ]; then
    CLIENT_PORT=$1
    if ! [[ "$CLIENT_PORT" =~ ^[0-9]+$ ]] || [ "$CLIENT_PORT" -lt 39501 ] || [ "$CLIENT_PORT" -gt 39990 ]; then
        echo -e "${RED}端口号必须在39501-39990之间${PLAIN}"
        exit 1
    fi
else
    CLIENT_PORT=$(shuf -i 39501-39990 -n 1)
fi

echo -e "${YELLOW}正在获取服务器 IPv4 地址...${PLAIN}"
SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}错误：无法获取服务器公网 IPv4 地址！${PLAIN}"
    exit 1
fi
echo -e "${GREEN}服务器 IPv4 地址：${SERVER_IP}${PLAIN}"

PASSWORD=$(grep -oP '(?<=-k ")[^"]*' /guard/conf/udp2raw.conf)
CLIENT_PRIVATE_KEY=$(cat /guard/conf/client_private.key)
SERVER_PUBLIC_KEY=$(cat /guard/conf/server_public.key)

CONF_DIR="/guard/conf"
QR_DIR="/guard/qrcodes"
WG_CONF_FILE="${CONF_DIR}/client_${CLIENT_PORT}.conf"
UDP2RAW_CONF_FILE="${CONF_DIR}/udp2raw_client_${CLIENT_PORT}.conf"
QR_FILE="${QR_DIR}/vpn_config_${CLIENT_PORT}.png"

# 生成客户端配置
echo -e "${YELLOW}生成 WireGuard 客户端配置: ${WG_CONF_FILE}${PLAIN}"
cat > "${WG_CONF_FILE}" << CLIENTCONF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.0.0.2/24
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_IP}:${CLIENT_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLIENTCONF

# 生成udp2raw客户端配置
echo -e "${YELLOW}生成 udp2raw 客户端配置: ${UDP2RAW_CONF_FILE}${PLAIN}"
cat > "${UDP2RAW_CONF_FILE}" << RAWCONF
-c
-l 127.0.0.1:39998 # 客户端udp2raw监听本地端口
-r ${SERVER_IP}:39500 # 服务器udp2raw监听的固定端口
-k "${PASSWORD}"
--raw-mode faketcp
--cipher-mode aes128cbc
--auth-mode hmac_sha1
--source-port ${CLIENT_PORT} # 客户端使用的源端口
RAWCONF

# 生成二维码
echo -e "${YELLOW}生成二维码: ${QR_FILE}${PLAIN}"
qrencode -t PNG -o "${QR_FILE}" < "${WG_CONF_FILE}"

echo -e "${GREEN}配置文件已生成：${PLAIN}"
echo "WireGuard配置：${WG_CONF_FILE}"
echo "udp2raw配置：${UDP2RAW_CONF_FILE}"
echo "二维码：${QR_FILE}"
GENSCRIPT
chmod +x /guard/scripts/generate_client.sh

# 配置系统服务
echo -e "${GREEN}配置系统服务...${PLAIN}"
cat > /etc/systemd/system/udp2raw.service << SERVICE
[Unit]
Description=udp2raw Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=/guard/bin/udp2raw_amd64 --conf-file /guard/conf/udp2raw.conf --log-level 3 #降低日志等级
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

# 配置防火墙规则
echo -e "${GREEN}配置防火墙规则...${PLAIN}"
ufw allow 22/tcp comment 'SSH'
ufw allow 39500/tcp comment 'UDP2RAW FakeTCP' # udp2raw 服务器监听端口
ufw allow 39998/udp comment 'WireGuard' # WireGuard 服务器监听端口
ufw status verbose # 显示防火墙状态

# 启用IP转发
echo -e "${GREEN}启用IP转发...${PLAIN}"
sed -i '/net.ipv4.ip_forward=1/s/^#//g' /etc/sysctl.conf
sysctl -p

# 启动服务
echo -e "${GREEN}启动并启用服务...${PLAIN}"
systemctl daemon-reload
systemctl enable --now udp2raw
systemctl enable --now wg-quick@wg0

# 检查服务状态
echo -e "${GREEN}检查服务状态...${PLAIN}"
sleep 2 # 等待服务启动
systemctl status wg-quick@wg0 --no-pager
systemctl status udp2raw --no-pager

# 克隆GitHub仓库 (如果需要的话)
# echo -e "${GREEN}克隆GitHub仓库...${PLAIN}"
# cd /root
# git clone https://github.com/sdkeio32/WireGuard_One-click_script_building_and_manual_script_building_Universal_version.git vpn_scripts || echo "仓库已存在或克隆失败"

# 生成初始客户端配置
echo -e "${GREEN}生成初始客户端配置...${PLAIN}"
/guard/scripts/generate_client.sh

echo -e "${GREEN}安装完成！${PLAIN}"
echo -e "${YELLOW}使用以下命令生成新的客户端配置：${PLAIN}"
echo -e "${GREEN}/guard/scripts/generate_client.sh [端口号]${PLAIN}"
echo -e "${YELLOW}端口号可选 (39501-39990)，不指定则随机生成${PLAIN}"
EOF

chmod +x /root/install_vpn.sh
echo "已更新 /root/install_vpn.sh 脚本，请执行它开始安装："
echo "/root/install_vpn.sh"
