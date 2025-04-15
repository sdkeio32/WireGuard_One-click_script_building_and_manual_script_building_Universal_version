#!/bin/bash

# Robust WireGuard + udp2raw Installer

# Exit on error, treat unset variables as errors
set -euo pipefail

# --- Configuration ---
WG_INTERFACE="wg0"
WG_PORT="39998"
WG_NET="10.0.0.0/24"
WG_SRV_IP="10.0.0.1"
WG_CLI_IP="10.0.0.2"
UDP2RAW_PORT="39500" # Fixed server listening port for udp2raw
CLIENT_SRC_PORT_MIN="39501"
CLIENT_SRC_PORT_MAX="39990"
GUARD_DIR="/guard"
UDP2RAW_BIN="${GUARD_DIR}/bin/udp2raw_amd64"
UDP2RAW_CONF="${GUARD_DIR}/conf/udp2raw.conf"
WG_CONF_FILE="/etc/wireguard/${WG_INTERFACE}.conf"
SERVER_PRIV_KEY="${GUARD_DIR}/conf/server_private.key"
SERVER_PUB_KEY="${GUARD_DIR}/conf/server_public.key"
CLIENT_PRIV_KEY="${GUARD_DIR}/conf/client_private.key"
CLIENT_PUB_KEY="${GUARD_DIR}/conf/client_public.key"
GEN_CLIENT_SCRIPT="${GUARD_DIR}/scripts/generate_client.sh"
UDP2RAW_SERVICE_FILE="/etc/systemd/system/udp2raw.service"
UDP2RAW_DL_URL="https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz"

# --- Colors ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PLAIN="\033[0m"

# --- Helper Functions ---
log() {
    echo -e "${BLUE}[INFO]${PLAIN} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${PLAIN} $1"
}

error() {
    echo -e "${RED}[ERROR]${PLAIN} $1" >&2
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用root权限运行此脚本"
    fi
}

stop_and_disable() {
    log "正在停止并禁用服务: $1..."
    systemctl stop "$1" &>/dev/null || true
    systemctl disable "$1" &>/dev/null || true
}

# --- Main Script ---

check_root

log "开始 WireGuard + udp2raw 安装/修复流程..."

# 1. Cleanup Phase
log "--- 清理旧的配置和状态 ---"
stop_and_disable "wg-quick@${WG_INTERFACE}"
stop_and_disable udp2raw

log "移除旧的 WireGuard 接口..."
ip link delete "${WG_INTERFACE}" &>/dev/null || true

log "清理相关的 iptables 规则..."
# Remove NAT rules (using the correct network)
iptables -t nat -D POSTROUTING -s "${WG_NET}" -o eth0 -j MASQUERADE &>/dev/null || true
iptables -t nat -D POSTROUTING -s "${WG_NET}" -o eth0 -j MASQUERADE &>/dev/null || true # Try again for duplicates
# Remove FORWARD rules (using the correct network)
iptables -D FORWARD -i "${WG_INTERFACE}" -j ACCEPT &>/dev/null || true
iptables -D FORWARD -o "${WG_INTERFACE}" -j ACCEPT &>/dev/null || true
iptables -D FORWARD -i "${WG_INTERFACE}" -j ACCEPT &>/dev/null || true # Try again
iptables -D FORWARD -o "${WG_INTERFACE}" -j ACCEPT &>/dev/null || true # Try again
# Remove potential old rules from previous runs
iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o eth0 -j MASQUERADE &>/dev/null || true

# Clean up udp2raw's auto-added rules (find chain name and delete)
UDP2RAW_CHAIN=$(iptables -L INPUT -n | grep -oP 'udp2raw[a-zA-Z0-9_]+')
if [ -n "$UDP2RAW_CHAIN" ]; then
    log "清理旧的 udp2raw iptables 链: $UDP2RAW_CHAIN"
    iptables -D INPUT -p tcp --dport "${UDP2RAW_PORT}" -j "$UDP2RAW_CHAIN" &>/dev/null || true # Adjust port if needed
    iptables -F "$UDP2RAW_CHAIN" &>/dev/null || true
    iptables -X "$UDP2RAW_CHAIN" &>/dev/null || true
fi

log "删除旧的配置文件和二进制文件..."
rm -f "${WG_CONF_FILE}"
rm -f "${UDP2RAW_SERVICE_FILE}"
rm -f "${GUARD_DIR}/conf/"* # Clear old keys, configs
rm -f "${GUARD_DIR}/qrcodes/"* # Clear old QR codes
rm -f "${UDP2RAW_BIN}" # Remove binary before redownload

# 2. Install Dependencies
log "--- 安装/更新依赖包 ---"
apt update
apt install -y wireguard qrencode iptables curl wget git ufw || error "依赖包安装失败"

# 3. Create Directories
log "创建目录结构: ${GUARD_DIR}"
mkdir -p "${GUARD_DIR}"/{bin,conf,scripts,qrcodes}

# 4. Download and Install udp2raw
log "--- 下载并安装 udp2raw ---"
cd /tmp
log "正在下载 udp2raw..."
wget -q "${UDP2RAW_DL_URL}" -O udp2raw_binaries.tar.gz || error "udp2raw 下载失败"
log "正在解压 udp2raw..."
tar -xzf udp2raw_binaries.tar.gz udp2raw_amd64 || error "udp2raw 解压失败"
log "正在复制 udp2raw 到 ${GUARD_DIR}/bin/ ..."
cp udp2raw_amd64 "${UDP2RAW_BIN}" || error "复制 udp2raw 失败"
chmod +x "${UDP2RAW_BIN}" || error "设置 udp2raw 执行权限失败"
log "验证 udp2raw 文件..."
ls -l "${UDP2RAW_BIN}"
log "清理临时文件..."
rm -f udp2raw_binaries.tar.gz udp2raw_amd64
cd "$OLDPWD" # Go back to previous directory

# 5. Generate Keys
log "--- 生成 WireGuard 密钥 ---"
wg genkey | tee "${SERVER_PRIV_KEY}" | wg pubkey > "${SERVER_PUB_KEY}" || error "生成服务器密钥失败"
wg genkey | tee "${CLIENT_PRIV_KEY}" | wg pubkey > "${CLIENT_PUB_KEY}" || error "生成客户端密钥失败"
log "密钥已保存到 ${GUARD_DIR}/conf/"

# 6. Create WireGuard Server Config
log "--- 创建 WireGuard 服务器配置 (${WG_CONF_FILE}) ---"
cat > "${WG_CONF_FILE}" << WGCONF
[Interface]
PrivateKey = $(cat "${SERVER_PRIV_KEY}")
Address = ${WG_SRV_IP}/24
ListenPort = ${WG_PORT}
# MTU = 1420 # Consider setting MTU on server too
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_NET} -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_NET} -o eth0 -j MASQUERADE

[Peer]
PublicKey = $(cat "${CLIENT_PUB_KEY}")
AllowedIPs = ${WG_CLI_IP}/32
WGCONF
log "WireGuard 服务器配置已创建"

# 7. Create udp2raw Server Config
log "--- 创建 udp2raw 服务器配置 (${UDP2RAW_CONF}) ---"
UDP2RAW_PASS="vpn_pass_$(date +%s | sha256sum | head -c 16)"
log "生成的 udp2raw 密码: ${UDP2RAW_PASS}"
cat > "${UDP2RAW_CONF}" << CONF
# udp2raw Server Config
-s
-l 0.0.0.0:${UDP2RAW_PORT} # Listen on fixed port
-r 127.0.0.1:${WG_PORT}  # Forward to local WireGuard port
-a                       # Auto add iptables rule for kernel RST blocking
-k "${UDP2RAW_PASS}"
--raw-mode faketcp
--cipher-mode aes128cbc
--auth-mode hmac_sha1
--log-level 3            # Set log level (0-6)
CONF
log "udp2raw 服务器配置已创建"

# 8. Create Client Generation Script
log "--- 创建客户端配置生成脚本 (${GEN_CLIENT_SCRIPT}) ---"
cat > "${GEN_CLIENT_SCRIPT}" << 'GENSCRIPT'
#!/bin/bash
set -euo pipefail
# Colors
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; PLAIN="\033[0m"
# Paths and Vars (Copied from parent script for standalone use)
GUARD_DIR="/guard"
CLIENT_PRIV_KEY_FILE="${GUARD_DIR}/conf/client_private.key"
SERVER_PUB_KEY_FILE="${GUARD_DIR}/conf/server_public.key"
UDP2RAW_CONF_FILE_SRV="${GUARD_DIR}/conf/udp2raw.conf"
WG_CLI_IP="10.0.0.2"
WG_PORT="39998" # WireGuard Server Port
UDP2RAW_PORT_SRV="39500" # udp2raw Server Port
CLIENT_SRC_PORT_MIN="39501"
CLIENT_SRC_PORT_MAX="39990"
CONF_DIR="${GUARD_DIR}/conf"
QR_DIR="${GUARD_DIR}/qrcodes"

# Check required server files
if [ ! -f "$CLIENT_PRIV_KEY_FILE" ] || [ ! -f "$SERVER_PUB_KEY_FILE" ] || [ ! -f "$UDP2RAW_CONF_FILE_SRV" ]; then
    echo -e "${RED}错误：缺少必要的服务器配置文件 (${CLIENT_PRIV_KEY_FILE}, ${SERVER_PUB_KEY_FILE}, ${UDP2RAW_CONF_FILE_SRV})！${PLAIN}"
    exit 1
fi

# Determine Client Source Port
if [ $# -eq 1 ]; then
    CLIENT_PORT=$1
    if ! [[ "$CLIENT_PORT" =~ ^[0-9]+$ ]] || [ "$CLIENT_PORT" -lt "$CLIENT_SRC_PORT_MIN" ] || [ "$CLIENT_PORT" -gt "$CLIENT_SRC_PORT_MAX" ]; then
        echo -e "${RED}错误：端口号必须在 ${CLIENT_SRC_PORT_MIN}-${CLIENT_SRC_PORT_MAX} 之间${PLAIN}"
        exit 1
    fi
    echo -e "${BLUE}使用指定端口: ${CLIENT_PORT}${PLAIN}"
else
    CLIENT_PORT=$(shuf -i "${CLIENT_SRC_PORT_MIN}-${CLIENT_SRC_PORT_MAX}" -n 1)
    echo -e "${BLUE}使用随机端口: ${CLIENT_PORT}${PLAIN}"
fi

# Get Server Public IP (Force IPv4)
echo -e "${YELLOW}正在获取服务器 IPv4 地址...${PLAIN}"
SERVER_IP=$(curl -4 -s --connect-timeout 10 ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}错误：无法获取服务器公网 IPv4 地址！请检查网络连接。${PLAIN}"
    exit 1
fi
echo -e "${GREEN}服务器 IPv4 地址: ${SERVER_IP}${PLAIN}"

# Read Keys and Password
CLIENT_PRIVATE_KEY=$(cat "${CLIENT_PRIV_KEY_FILE}")
SERVER_PUBLIC_KEY=$(cat "${SERVER_PUB_KEY_FILE}")
PASSWORD=$(grep -oP '(?<=-k ")[^"]*' "${UDP2RAW_CONF_FILE_SRV}") || { echo -e "${RED}无法从 ${UDP2RAW_CONF_FILE_SRV} 读取密码!${PLAIN}"; exit 1; }

# Define output file paths
WG_CONF_FILE="${CONF_DIR}/client_${CLIENT_PORT}.conf"
UDP2RAW_CONF_FILE_CLI="${CONF_DIR}/udp2raw_client_${CLIENT_PORT}.conf"
QR_FILE="${QR_DIR}/vpn_config_${CLIENT_PORT}.png"

# --- Generate WireGuard Client Config ---
echo -e "${YELLOW}生成 WireGuard 客户端配置: ${WG_CONF_FILE}${PLAIN}"
cat > "${WG_CONF_FILE}" << CLIENTWGCONF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${WG_CLI_IP}/32 # Use /32 for client
DNS = 8.8.8.8, 1.1.1.1
MTU = 1280 # Crucial for udp2raw encapsulation

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
# Endpoint MUST point to the local udp2raw client instance
Endpoint = 127.0.0.1:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0 # Allow all IPv4 and IPv6 traffic
PersistentKeepalive = 25
CLIENTWGCONF

# --- Generate udp2raw Client Config (for reference/Linux client) ---
# Mobile clients need manual configuration using these parameters.
echo -e "${YELLOW}生成 udp2raw 客户端参考配置: ${UDP2RAW_CONF_FILE_CLI}${PLAIN}"
cat > "${UDP2RAW_CONF_FILE_CLI}" << CLIENTRAWCONF
# udp2raw Client Config (for reference or Linux client)
# For mobile, configure your udp2raw app with these settings:
# Server Address: ${SERVER_IP}:${UDP2RAW_PORT_SRV}
# Password: ${PASSWORD}
# Local Listening Address (for WireGuard): 127.0.0.1:${WG_PORT} (or 0.0.0.0:${WG_PORT})
# Client Source Port: ${CLIENT_PORT} (This is important!)
# Mode: faketcp, Cipher: aes128cbc, Auth: hmac_sha1

-c
-l 127.0.0.1:${WG_PORT} # Listen locally for WireGuard connection
-r ${SERVER_IP}:${UDP2RAW_PORT_SRV} # Connect to server's udp2raw port
-k "${PASSWORD}"
--raw-mode faketcp
--cipher-mode aes128cbc
--auth-mode hmac_sha1
--source-port ${CLIENT_PORT} # Use the designated source port
CLIENTRAWCONF

# --- Generate QR Code ---
echo -e "${YELLOW}生成二维码 (WireGuard Config): ${QR_FILE}${PLAIN}"
qrencode -t PNG -o "${QR_FILE}" < "${WG_CONF_FILE}" || { echo -e "${RED}生成二维码失败!${PLAIN}"; exit 1; }

echo -e "${GREEN}--- 客户端配置生成完毕 ---${PLAIN}"
echo "WireGuard 配置 (用于二维码扫描): ${WG_CONF_FILE}"
echo "udp2raw 参考配置 (用于手动配置): ${UDP2RAW_CONF_FILE_CLI}"
echo "二维码图片: ${QR_FILE}"
echo -e "${YELLOW}重要: 您需要在客户端手动配置 udp2raw 应用，使用上述 udp2raw 参考配置中的参数。然后扫描二维码配置 WireGuard。${PLAIN}"

GENSCRIPT
chmod +x "${GEN_CLIENT_SCRIPT}" || error "设置客户端生成脚本权限失败"
log "客户端生成脚本已创建"

# 9. Configure Systemd Service for udp2raw
log "--- 配置 udp2raw Systemd 服务 ---"
cat > "${UDP2RAW_SERVICE_FILE}" << SERVICE
[Unit]
Description=udp2raw Server Service (Tunneling UDP over FakeTCP)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${UDP2RAW_BIN} --conf-file ${UDP2RAW_CONF}
Restart=on-failure
RestartSec=5s
# Limit resources if needed
# CPUQuota=50%
# MemoryMax=256M

[Install]
WantedBy=multi-user.target
SERVICE
log "udp2raw 服务文件已创建"

# 10. Configure Firewall (UFW)
log "--- 配置防火墙 (UFW) ---"
log "重置 UFW 规则..."
ufw --force reset # Start clean
log "启用 UFW..."
ufw --force enable # Enable before adding rules
log "设置默认规则..."
ufw default deny incoming
ufw default allow outgoing
log "允许 SSH (22/tcp)..."
ufw allow 22/tcp comment 'SSH'
log "允许 WireGuard (${WG_PORT}/udp)..."
ufw allow "${WG_PORT}/udp" comment 'WireGuard VPN'
log "允许 udp2raw (${UDP2RAW_PORT}/tcp - FakeTCP)..."
ufw allow "${UDP2RAW_PORT}/tcp" comment 'udp2raw FakeTCP'
# log "允许客户端源端口范围 (${CLIENT_SRC_PORT_MIN}:${CLIENT_SRC_PORT_MAX}/tcp)..." # Generally not needed on server
# ufw allow ${CLIENT_SRC_PORT_MIN}:${CLIENT_SRC_PORT_MAX}/tcp comment 'udp2raw Client Ports' # Usually not required
log "重新加载 UFW 规则..."
ufw reload
log "显示 UFW 状态:"
ufw status verbose

# 11. Enable IP Forwarding
log "--- 启用 IPv4 转发 ---"
sed -i -e '/^#net.ipv4.ip_forward=1/s/^#//' -e '/^net.ipv4.ip_forward=0/s/0/1/' /etc/sysctl.conf
sysctl -p
if ! sysctl net.ipv4.ip_forward | grep -q "1"; then
    error "启用 IP 转发失败!"
fi
log "IP 转发已启用"

# 12. Start and Enable Services
log "--- 启动并启用服务 ---"
log "重新加载 systemd..."
systemctl daemon-reload
log "启动并启用 udp2raw 服务..."
systemctl enable --now udp2raw || error "启动/启用 udp2raw 服务失败"
log "启动并启用 WireGuard 服务 (${WG_INTERFACE})..."
systemctl enable --now "wg-quick@${WG_INTERFACE}" || error "启动/启用 WireGuard 服务失败"

# 13. Final Status Checks
log "--- 最终状态检查 ---"
sleep 3 # Give services a moment to start
log "检查 udp2raw 服务状态:"
systemctl status udp2raw --no-pager || warn "udp2raw 服务状态异常!"
log "检查 WireGuard 服务状态:"
systemctl status "wg-quick@${WG_INTERFACE}" --no-pager || warn "WireGuard 服务状态异常!"
log "显示 WireGuard 接口信息:"
wg show "${WG_INTERFACE}" || warn "无法显示 WireGuard 接口信息!"

# 14. Generate Initial Client Config
log "--- 生成初始客户端配置 ---"
"${GEN_CLIENT_SCRIPT}"

# 15. Completion Message
log "--- 安装/修复完成！ ---"
echo -e "${GREEN}WireGuard + udp2raw 已成功配置.${PLAIN}"
echo -e "${YELLOW}初始客户端配置已生成。请查看 ${GUARD_DIR}/qrcodes/ 中的二维码和 ${GUARD_DIR}/conf/ 中的配置文件。${PLAIN}"
echo -e "${YELLOW}重要提醒:${PLAIN}"
echo -e " 1. ${RED}您必须在手机/客户端上手动配置 udp2raw 应用${PLAIN}，使用 ${GUARD_DIR}/conf/udp2raw_client_*.conf 文件中的参数。"
echo -e " 2. 然后使用 WireGuard 应用扫描 ${GUARD_DIR}/qrcodes/vpn_config_*.png 中的二维码。"
echo -e " 3. 确保在 WireGuard 客户端配置中设置 ${GREEN}MTU = 1280${PLAIN}。"
echo -e " 4. 连接时，${GREEN}先启动客户端的 udp2raw，再启动 WireGuard${PLAIN}。"
echo ""
echo -e "使用以下命令生成更多客户端配置 (端口可选):"
echo -e "  ${GREEN}${GEN_CLIENT_SCRIPT} [端口号]${PLAIN}"
echo -e "  (端口号范围: ${CLIENT_SRC_PORT_MIN}-${CLIENT_SRC_PORT_MAX})"
