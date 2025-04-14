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

# 拉起容器（初始构建）
docker build -t guards_image /root/guard
docker run -d --name guards \
  --cap-add=NET_ADMIN \
  --network=host \
  --restart=always \
  guards_image

echo "部署完成！容器名称 guards，WireGuard 自动运行，客户端配置文件保存在 /root/guard/export"
