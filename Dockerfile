FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y \
    wireguard \
    iptables \
    qrencode \
    curl \
    unzip \
    wget \
    supervisor \
    cron \
    iproute2 \
    iputils-ping \
    vim \
    net-tools \
    python3 \
    dnsutils \
    git \
    && apt clean

# 安装 udp2raw（新链接）和 udp2ws
RUN mkdir -p /opt/tools && cd /opt/tools && \
    wget https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200708.0/udp2raw_amd64 -O /usr/local/bin/udp2raw && \
    wget https://github.com/yonggekkk/udp2ws/releases/latest/download/udp2ws-linux-amd64 -O /usr/local/bin/udp2ws && \
    chmod +x /usr/local/bin/udp2raw /usr/local/bin/udp2ws

# 添加配置文件和启动脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
