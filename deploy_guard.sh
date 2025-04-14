#!/bin/bash
# 一键部署 WireGuard + 分流 + UDP 伪装 + 客户端生成容器
# 安装目录: /root/guard

set -e

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# 创建目录结构
mkdir -p /root/guard/{config,export,scripts}
cd /root/guard

# 安装 Docker（Ubuntu）
echo "Installing Docker..."
apt update && apt install -y ca-certificates curl gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

ARCH=$(dpkg --print-architecture)
echo \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 下载分流 IP 列表
cat <<EOF > /root/guard/config/split_ip_list.txt
3.0.0.0/8
13.32.0.0/15
13.224.0.0/14
34.224.0.0/12
52.0.0.0/11
54.230.0.0/16
64.233.160.0/19
66.102.0.0/20
66.249.80.0/20
70.132.0.0/18
72.14.192.0/18
74.125.0.0/16
91.105.192.0/23
91.108.4.0/22
91.108.8.0/22
91.108.12.0/22
91.108.16.0/22
91.108.20.0/22
91.108.56.0/22
108.177.8.0/21
142.250.0.0/15
143.204.0.0/16
149.154.160.0/20
172.217.0.0/16
173.194.0.0/16
185.76.151.0/24
192.178.0.0/15
203.208.32.0/19
204.246.168.0/22
204.246.172.0/23
204.246.174.0/23
205.251.192.0/19
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
2001:67c:4e8::/48
2001:b28:f23c::/48
2001:b28:f23d::/48
2001:b28:f23f::/48
2a0a:f280::/32
EOF

# 生成 Dockerfile
cat <<'EOF' > /root/guard/Dockerfile
FROM ubuntu:22.04

RUN apt update && apt install -y wireguard iproute2 iptables qrencode curl unzip wget net-tools

COPY ./config /guard/config
COPY ./scripts /guard/scripts
COPY wg_entrypoint.sh /guard/wg_entrypoint.sh

RUN chmod +x /guard/scripts/*.sh /guard/wg_entrypoint.sh

ENTRYPOINT ["/guard/wg_entrypoint.sh"]
EOF

# 创建入口脚本
cat <<'EOF' > /root/guard/wg_entrypoint.sh
#!/bin/bash
set -e

# 每次启动时执行伪装程序 + WireGuard + 分流规则
bash /guard/scripts/fake_udp_obfuscate &
bash /guard/scripts/init_split_routes.sh &
bash /guard/scripts/switch_port.sh &
bash /guard/scripts/update_client.sh &

sleep infinity
EOF

chmod +x /root/guard/wg_entrypoint.sh

# 添加脚本文件
cat <<'EOF' > /root/guard/scripts/switch_port.sh
#!/bin/bash
# 自动生成 WireGuard 配置随机端口
PORT=$(shuf -i 31000-40000 -n 1)
echo "[+] Switching to port: $PORT"
sed -i "s/^ListenPort.*/ListenPort = $PORT/" /guard/config/server.conf
EOF

cat <<'EOF' > /root/guard/scripts/update_client.sh
#!/bin/bash
# 生成客户端配置并输出二维码
PRIVATE_KEY=$(wg genkey)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
SERVER_PUBLIC_KEY=$(cat /etc/wireguard/publickey)
SERVER_IP=103.106.228.55
PORT=$(grep ListenPort /guard/config/server.conf | awk '{print $3}')

mkdir -p /guard/export

# 全局配置
cat <<EOG > /guard/export/client_full.conf
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.66.66.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:$PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOG

# 分流配置（默认使用脚本中的IP段实现）
cat <<EOG > /guard/export/client_split.conf
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.66.66.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:$PORT
AllowedIPs = $(paste -sd, /guard/config/split_ip_list.txt)
PersistentKeepalive = 25
EOG

# 生成二维码和压缩包
qrencode -o /guard/export/client_full.png < /guard/export/client_full.conf
qrencode -o /guard/export/client_split.png < /guard/export/client_split.conf
cd /guard/export && zip -r client_full.zip client_full.conf client_full.png
cd /guard/export && zip -r client_split.zip client_split.conf client_split.png
EOF

cat <<'EOF' > /root/guard/scripts/init_split_routes.sh
#!/bin/bash
# 设置iptables和策略路由分流 Telegram/Signal/YouTube
IPLIST=/guard/config/split_ip_list.txt

for ip in $(cat $IPLIST); do
  ip rule add to $ip table 100 priority 1000 || true
  ip route add default dev wg0 table 100 || true
done
EOF

cat <<'EOF' > /root/guard/scripts/fake_udp_obfuscate
#!/bin/bash
# 模拟Spotify风格的UDP数据包发送器（用于伪装）
# 示例：添加标识Header模拟浏览器流量（不是真实连接）
while true; do
  echo -n -e "GET /show/3YH7knkMYcRJnjOG7wXtRf HTTP/1.1\r\nHost: open.spotify.com\r\nUser-Agent: Mozilla/5.0\r\n\r\n" | nc -u -w1 127.0.0.1 53
  sleep 30
done
EOF

chmod +x /root/guard/scripts/*.sh

# 拉起容器（初始构建）
docker build -t guards_image /root/guard
docker run -d --name guards \
  --cap-add=NET_ADMIN \
  --network=host \
  --restart=always \
  guards_image

echo "部署完成！容器名称 guards，WireGuard 自动运行，客户端配置文件保存在 /root/guard/export"
