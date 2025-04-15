#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

print() {
  echo -e "${GREEN}[√]${RESET} $1"
}
warn() {
  echo -e "${YELLOW}[!]${RESET} $1"
}
error() {
  echo -e "${RED}[X]${RESET} $1"
}

echo "🔍 正在执行 WireGuard + Hysteria2 一键诊断..."

# 检查 WireGuard 是否正常启动
if ip link show wg0 &>/dev/null; then
  print "WireGuard 接口 wg0 存在"
else
  error "WireGuard 接口 wg0 不存在，请检查 wg-quick@wg0 服务"
fi

# 检查 WireGuard 是否启用 systemd
if systemctl is-active --quiet wg-quick@wg0; then
  print "WireGuard 服务 (wg-quick@wg0) 正常运行"
else
  error "WireGuard 服务未运行，尝试执行：systemctl restart wg-quick@wg0"
fi

# 检查 IPv4 转发是否开启
if sysctl net.ipv4.ip_forward | grep -q "= 1"; then
  print "IPv4 转发已启用"
else
  error "IPv4 转发未启用，请执行：sysctl -w net.ipv4.ip_forward=1"
fi

# 检查 Hysteria2 服务是否运行
if systemctl is-active --quiet hysteria-server; then
  print "Hysteria2 服务正常运行"
else
  error "Hysteria2 服务未运行，请执行：systemctl restart hysteria-server"
fi

# 检查 Hysteria2 端口监听
PORT=$(grep '^listen:' /etc/hysteria/config.yaml | awk '{print $2}' | sed 's/://')
if ss -unlp | grep -q ":$PORT"; then
  print "Hysteria2 UDP 端口 $PORT 正在监听"
else
  error "Hysteria2 端口 $PORT 未监听，请确认配置"
fi

# 检查二维码是否生成
if [[ -f "/root/guard/qrcode/qr-global.png" ]] && [[ -f "/root/guard/qrcode/qr-split.png" ]]; then
  print "二维码已生成：qr-global.png 和 qr-split.png"
else
  error "二维码未生成，请检查脚本执行过程"
fi

# 检查公网 IP 和代理 IP 是否不同（判断代理是否生效）
WG_IP=$(curl -s --interface wg0 https://api.ipify.org || echo "N/A")
REAL_IP=$(curl -s https://api.ipify.org)

echo -e "${YELLOW}[?]${RESET} 公网出口 IP: $REAL_IP"
echo -e "${YELLOW}[?]${RESET} 通过 wg0 的 IP: $WG_IP"

if [[ "$WG_IP" != "$REAL_IP" && "$WG_IP" != "N/A" ]]; then
  print "代理出口 IP 与真实 IP 不一致，说明代理已生效"
else
  warn "代理似乎未生效（可能配置错误或未生效）"
fi

echo -e "\n✅ ${GREEN}诊断完成！${RESET} 请根据上方输出修复问题后重试连接。"
