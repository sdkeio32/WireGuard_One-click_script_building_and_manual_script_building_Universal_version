#!/bin/bash

# 定义颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 错误处理函数
handle_error() {
    echo -e "${RED}错误: $1${NC}"
    exit 1
}

# 设置错误处理
set -e
trap 'handle_error "第 $LINENO 行发生错误: $BASH_COMMAND"' ERR

echo -e "${GREEN}开始部署 WireGuard + Hysteria2 服务...${NC}"

# 清理现有服务和端口
cleanup_services() {
    echo -e "${YELLOW}正在清理现有服务...${NC}"
    
    echo "停止 WireGuard 服务..."
    wg-quick down wg0 2>/dev/null || true
    
    echo "删除 WireGuard 接口..."
    ip link delete wg0 2>/dev/null || true
    
    echo "停止 Hysteria2 进程..."
    pkill -f hysteria2 2>/dev/null || true
    
    echo "等待端口释放..."
    sleep 2
    
    echo -e "${GREEN}服务清理完成${NC}"
}

# 创建目录结构
create_directories() {
    echo -e "${YELLOW}创建目录结构...${NC}"
    
    echo "删除旧的 guard 目录..."
    rm -rf /guard
    
    echo "创建新的目录结构..."
    mkdir -p /guard/scripts
    mkdir -p /guard/config/wireguard
    mkdir -p /guard/config/hysteria2
    mkdir -p /guard/export/full_proxy
    mkdir -p /guard/export/split_routing
    mkdir -p /etc/wireguard
    mkdir -p /guard/config/cert
    
    echo -e "${GREEN}目录创建完成${NC}"
}

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}安装必要组件...${NC}"
    
    echo "更新包列表..."
    apt update
    
    echo "安装所需软件包..."
    apt install -y wireguard qrencode curl wget net-tools openssl
    
    echo -e "${GREEN}组件安装完成${NC}"
}

# 下载 Hysteria2
download_hysteria() {
    echo -e "${YELLOW}下载 Hysteria2...${NC}"
    
    wget -O /guard/hysteria2 https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64 || handle_error "下载 Hysteria2 失败"
    chmod +x /guard/hysteria2
    
    echo -e "${GREEN}Hysteria2 下载完成${NC}"
}

# 生成证书
generate_certificates() {
    echo -e "${YELLOW}生成自签名证书...${NC}"
    
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /guard/config/cert/private.key \
        -out /guard/config/cert/certificate.crt \
        -subj "/CN=guard.local" || handle_error "证书生成失败"
    
    echo -e "${GREEN}证书生成完成${NC}"
}

# 主程序
main() {
    # 执行清理
    cleanup_services
    
    # 创建目录
    create_directories
    
    # 安装依赖
    install_dependencies
    
    # 下载 Hysteria2
    download_hysteria
    
    # 生成证书
    generate_certificates
    
    echo -e "${YELLOW}创建配置文件...${NC}"
    
    # 创建配置生成脚本
    cat > /guard/scripts/generate_configs.sh << 'EOF'
#!/bin/bash
set -e

# 获取可用端口
get_available_port() {
    local port
    while true; do
        port=$(shuf -i 39500-39900 -n 1)
        if ! netstat -tuln | grep -q ":$port "; then
            echo "$port"
            break
        fi
    done
}

# 生成密钥
SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
PORT=$(get_available_port)
SERVER_IP=$(curl -s ifconfig.me)

# 生成配置文件
echo "生成 WireGuard 服务器配置..."
cat > /etc/wireguard/wg0.conf << WGEOF
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

echo "生成客户端配置..."
# 配置文件生成代码...（与之前相同）

echo "生成 Hysteria2 配置..."
cat > /guard/config/hysteria2/config.json << HYEOF
{
  "listen": ":${PORT}",
  "tls": {
    "cert": "/guard/config/cert/certificate.crt",
    "key": "/guard/config/cert/private.key"
  },
  "auth": {
    "type": "none"
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
HYEOF

echo "配置生成完成"
EOF

    # 设置权限
    chmod +x /guard/scripts/generate_configs.sh
    
    echo -e "${YELLOW}生成初始配置...${NC}"
    bash /guard/scripts/generate_configs.sh
    
    echo -e "${YELLOW}启动服务...${NC}"
    wg-quick up wg0
    /guard/hysteria2 server -c /guard/config/hysteria2/config.json
    
    echo -e "${GREEN}部署完成！${NC}"
}

# 执行主程序
main
