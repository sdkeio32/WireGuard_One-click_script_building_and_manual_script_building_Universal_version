#!/bin/bash

echo "[+] 开始部署 WireGuard 容器环境..."

# 安装 Docker
if ! command -v docker >/dev/null 2>&1; then
  echo "[+] 安装 Docker..."
  apt update -y
  apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io
fi

# 克隆目录到 /root/guard
echo "[+] 准备部署目录 /root/guard..."
mkdir -p /root/guard
cd /root/guard

# 如果你托管项目为 public，可直接克隆，否则跳过此步骤
if [ ! -f Dockerfile ]; then
  echo "[!] 请将代码 clone 到此目录或手动上传"
  exit 1
fi

# 启动构建与运行
echo "[+] 执行构建并启动容器..."
chmod +x *.sh config/*.conf config/split_ips/*.txt
bash ./build_and_run.sh

echo "[+] 完成！客户端配置已生成，请查看 /root/guard/export/ 文件夹中的二维码与配置文件。"
