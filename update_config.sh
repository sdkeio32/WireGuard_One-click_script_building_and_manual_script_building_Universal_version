#!/bin/bash

WG_CONFIG_DIR="/etc/wireguard"
GUARD_DIR="/root/guard"
CONF_DIR="$GUARD_DIR/config"
EXPORT_DIR="$GUARD_DIR/export"

PRIVATE_KEY=$(wg genkey)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
PRESHARED_KEY=$(wg genpsk)

PORT=$((RANDOM % 9001 + 31000))
SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
MTU=1380

cat > "$WG_CONFIG_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.10.0.1/24
ListenPort = $PORT
MTU = $MTU
SaveConfig = true

[Peer]
PublicKey = $PUBLIC_KEY
PresharedKey = $PRESHARED_KEY
AllowedIPs = 10.10.0.2/32
EOF

cat > "$EXPORT_DIR/client_full.conf" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.10.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $PUBLIC_KEY
PresharedKey = $PRESHARED_KEY
Endpoint = $SERVER_IP:$PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

cat > "$EXPORT_DIR/client_split.conf" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.10.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $PUBLIC_KEY
PresharedKey = $PRESHARED_KEY
Endpoint = $SERVER_IP:$PORT
AllowedIPs = $(cat "$CONF_DIR/split_ips/"*.txt | paste -sd "," -)
PersistentKeepalive = 25
EOF

qrencode -t ansiutf8 < "$EXPORT_DIR/client_full.conf" > "$EXPORT_DIR/full_qr.txt"
qrencode -t ansiutf8 < "$EXPORT_DIR/client_split.conf" > "$EXPORT_DIR/split_qr.txt"

qrencode -o "$EXPORT_DIR/full.png" < "$EXPORT_DIR/client_full.conf"
qrencode -o "$EXPORT_DIR/split.png" < "$EXPORT_DIR/client_split.conf"

cd "$EXPORT_DIR"
zip -q full.zip client_full.conf full.png
zip -q split.zip client_split.conf split.png
