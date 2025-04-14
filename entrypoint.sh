#!/bin/bash

set -e

WG_CONFIG_DIR="/etc/wireguard"
GUARD_DIR="/root/guard"
EXPORT_DIR="$GUARD_DIR/export"
CONF_DIR="$GUARD_DIR/config"
SPLIT_IP_DIR="$CONF_DIR/split_ips"

mkdir -p "$WG_CONFIG_DIR" "$EXPORT_DIR"

# 载入服务器配置（初始端口随机生成一次）
bash "$GUARD_DIR/update_config.sh"

# 启用 WireGuard
wg-quick up wg0

# 应用分流策略
ip rule add fwmark 1 table 100 || true
ip route add default dev wg0 table 100 || true

iptables -t mangle -F
iptables -t mangle -A PREROUTING -p udp -j MARK --set-mark 1

# 加载分流 IP 段
for ip_file in "$SPLIT_IP_DIR"/*.txt; do
  while read ip; do
    [ -n "$ip" ] && iptables -t mangle -A PREROUTING -d "$ip" -j MARK --set-mark 1
  done < "$ip_file"
done

# 启动伪装服务（UDP over WebSocket + UDP2RAW）
udp2ws -s -l0.0.0.0:40001 -t127.0.0.1:31001 >/dev/null 2>&1 &
udp2raw -s -l0.0.0.0:40002 -r127.0.0.1:31001 -a -k "wireguardPSK" --cipher-mode xor --auth-mode simple >/dev/null 2>&1 &

# 定期更新配置（5分钟）
(crontab -l 2>/dev/null; echo "*/5 * * * * bash $GUARD_DIR/update_config.sh") | crontab -

# 保持前台运行，避免容器退出
tail -f /dev/null
