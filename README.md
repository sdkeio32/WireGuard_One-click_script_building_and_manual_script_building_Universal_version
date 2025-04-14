================================================

**WireGuard 一鍵腳本搭建和手動腳本搭建 通用版**
提示：僅供學習記錄，請勿用於違法用途，請勿違反當地法律
推薦使用 Ubuntu 22.04

隨時聯繫
telegram：

https://t.me/tgbot996

Telegram 用戶名： @tgbot996

我是美籍華人，如果您有任何付款需求，可以聯繫我。

僅支持 USDT 支付

================================================

**WireGuard One-click script building and manual script building Universal version** 
Tip: For learning records only, do not use for illegal purposes, and do not violate local laws
**Recommended use Ubuntu 22.04** 
Feel free to get in touch

telegram:

https://t.me/tgbot996

Telegram username: @tgbot996

I am a Chinese American, you can contact me if you have any payment needs.

Only USDT payments are supported

================================================

**WireGuard 一键脚本搭建和手动脚本搭建 通用版**
提示：仅供学习记录，请勿用于违法用途，请勿违反当地法律


推荐使用 Ubuntu 22.04

随时联系
telegram：

https://t.me/tgbot996

Telegram 用户名： @tgbot996

我是美籍华人，如果您有任何付款需求，可以联系我。

仅支持 USDT 支付

================================================


一键部署命令（所有代码内容没有加密，无后门，如果觉得有问题，可以手动操作每行代码）：
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sdkeio32/WireGuard_One-click_script_building_and_manual_script_building_Universal_version/main/deploy_guard.sh)"

cd /root/guard
docker stop guards
docker rm guards
docker build -t guards_image .
docker run -d --name guards --cap-add=NET_ADMIN --network=host --restart=always guards_image

docker exec -it guards bash
bash /guard/scripts/update_client.sh

进入容器：
docker exec -it guards bash

重新生成密钥
wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey

写入服务端配置（务必确保 ListenPort 是当前的）
PORT=$(shuf -i 31000-40000 -n 1)
cat <<EOF > /guard/config/server.conf
[Interface]
PrivateKey = $(cat /etc/wireguard/privatekey)
Address = 10.66.66.1/24
ListenPort = $PORT
EOF

保存后再次生成客户端配置
bash /guard/scripts/update_client.sh

ls /guard/export

复制二维码从容器到宿主机
docker cp guards:/guard/export /root/guard/






