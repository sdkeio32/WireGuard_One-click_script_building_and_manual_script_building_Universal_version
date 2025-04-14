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
    && apt clean

# 安装 udp2raw 和 udp2ws
RUN mkdir -p /opt/tools && cd /opt/tools && \
    wget -O udp2raw https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200708.0/udp2raw_binaries.tar.gz && \
    tar -xzvf udp2raw && \
    wget -O udp2ws https://github.com/yonggekkk/udp2ws/releases/download/v1.0.3/udp2ws-linux-amd64 && \
    chmod +x udp2raw_amd64 && chmod +x udp2ws-linux-amd64 && mv udp2raw_amd64 /usr/local/bin/udp2raw && mv udp2ws-linux-amd64 /usr/local/bin/udp2ws

# 添加配置文件和启动脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
