#!/bin/bash
#✅ 检测服务端能否访问外网

#✅ 检查 WireGuard 隧道状态

#✅ 检查 Hysteria2 是否监听成功

#✅ 检测 NAT 是否生效

#✅ 检查客户端是否传输数据

set -e

echo "🌐 检查公网 IPv4 出口..."
curl -s --max-time 5 https://api.ipify.org && echo " ✅ 正常" || echo " ❌ 失败"

echo "🌍 检查 DNS 是否能解析 Google..."
dig +short google.com | grep -Eo '[0-9.]+' || echo "❌ DNS 失败"

echo "📡 检查 WireGuard 状态..."
sudo wg show || echo "❌ wg 未启动"

echo "📶 检查接口 wg0 是否存在..."
ip link show wg0 >/dev/null && echo "✅ wg0 存在" || echo "❌ wg0 不存在"

echo "🔌 检查 iptables NAT 转发是否存在..."
sudo iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE | grep "10.10.0.0" && echo "✅ NAT 正常" || echo "❌ NAT 缺失"

echo "🔍 检查 Hysteria2 容器是否在运行..."
docker ps | grep hysteria2 && echo "✅ 容器运行中" || echo "❌ 容器未运行"

echo "🛰️ 检查 Hysteria2 是否监听 UDP..."
ss -lunp | grep hysteria | grep 395 | grep -o 'udp.*395[0-9]+' || echo "❌ Hysteria2 未监听"

echo "📡 模拟使用 wg0 出口访问 google.com..."
curl --interface wg0 -I --max-time 5 https://www.google.com && echo "✅ wg0 出口成功" || echo "❌ wg0 出口失败"

echo -e "\n✅ 完成诊断！如果有 ❌ 请截图或贴我，我来修复"
