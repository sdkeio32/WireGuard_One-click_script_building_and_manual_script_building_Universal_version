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

# 安装 udp2raw（保持原有 TLS/XOR 混淆能力）
RUN mkdir -p /opt/tools && cd /opt/tools && \
    wget -O udp2raw.tar.gz https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200708.0/udp2raw_binaries.tar.gz && \
    tar -xzvf udp2raw.tar.gz && \
    mv udp2raw_amd64 /usr/local/bin/udp2raw && chmod +x /usr/local/bin/udp2raw

# 安装 gost（v3）
RUN wget -O /usr/local/bin/gost https://github.com/go-gost/gost/releases/download/v3.0.0-beta.13/gost-linux-amd64-3.0.0-beta.13 && \
    chmod +x /usr/local/bin/gost

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
