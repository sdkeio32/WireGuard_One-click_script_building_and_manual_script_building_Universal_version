#!/bin/bash

set -e

WG_PORT_FILE="/etc/wireguard/wg0.conf"
CONFIG_PATH="/etc/hysteria/config.yaml"
CERT_PATH="/etc/hysteria/cert.pem"
KEY_PATH="/etc/hysteria/key.pem"

echo "🔧 开始生成 Hysteria2 配置..."

# 检查 WireGuard 配置文件是否存在
if [ ! -f "$WG_PORT_FILE" ]; then
  echo "❌ 找不到 WireGuard 配置: $WG_PORT_FILE"
  exit 1
fi

# 提取 WireGuard 的端口
WG_PORT=$(grep -E '^ListenPort' "$WG_PORT_FILE" | awk '{print $3}')
if [ -z "$WG_PORT" ]; then
  echo "❌ 无法从 wg0.conf 中提取监听端口"
  exit 1
fi

# 默认监听端口（可自定义）
HYSTERIA_PORT=39514

# 检查 TLS 证书是否存在
if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
  echo "❌ 缺少 TLS 证书或密钥文件："
  echo "  cert: $CERT_PATH"
  echo "  key:  $KEY_PATH"
  exit 1
fi

# 生成配置
cat > "$CONFIG_PATH" <<EOF
listen: :$HYSTERIA_PORT

tls:
  cert: $CERT_PATH
  key: $KEY_PATH

auth:
  mode: "disabled"

forward:
  type: wireguard
  server: 127.0.0.1:$WG_PORT
EOF

echo "✅ 配置文件已生成：$CONFIG_PATH"
echo "🔁 WireGuard 端口：$WG_PORT"
echo "📡 Hysteria2 监听端口：$HYSTERIA_PORT"
echo ""
echo "👉 可执行以下命令启动服务："
echo "   systemctl restart hysteria-server"
