#!/bin/bash

set -e

WG_CONFIG_DIR="/etc/wireguard"
GUARD_DIR="/root/guard"
EXPORT_DIR="$GUARD_DIR/export"
CONF_DIR="$GUARD_DIR/config"
SPLIT_IP_DIR="$CONF_DIR/split_ips"

mkdir -p "$WG_CONFIG_DIR" "$EXPORT_DIR"

# 初始配置
bash "$GUARD_DIR/update_config.sh"

# 启动 WireGuard
wg-quick up wg0

# 路由策略（分流）
ip rule add fwmark 1 table 100 || true
ip route add default dev wg0 table 100 || true

iptables -t mangle -F
iptables -t mangle -A PREROUTING -p udp -j MARK --set-mark 1

# 加载分流 IP
for ip_file in "$SPLIT_IP_DIR"/*.txt; do
  while read ip; do
    [ -n "$ip" ] && iptables -t mangle -A PREROUTING -d "$ip" -j MARK --set-mark 1
  done < "$ip_file"
done

# 启动 UDP over WebSocket (gost)
gost -L=udp://:40001?ws=true >/dev/null 2>&1 &

# 启动 udp2raw 混淆（伪装 TLS 流量）
udp2raw -s -l0.0.0.0:40002 -r127.0.0.1:31001 -a -k "wireguardPSK" --cipher-mode xor --auth-mode simple >/dev/null 2>&1 &

# 定时任务自动换端口
(crontab -l 2>/dev/null; echo "*/5 * * * * bash $GUARD_DIR/update_config.sh") | crontab -

# 保持容器前台运行
tail -f /dev/null
