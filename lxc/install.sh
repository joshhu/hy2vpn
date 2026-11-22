#!/usr/bin/env bash
# 在 LXC 裡安裝 hy2vpn：sing-box 直接跑在系統上（不用 Docker），自己撥 PPPoE，DuckDNS 即時更新。
# 前提：用 lxc/create-ct.sh 建立的 LXC（eth1 直通數據機、/dev/ppp 已經傳進來），repo 已經放進來。
# 用法：PPPOE_USER=12345678@hinet.net PPPOE_PASS=xxxx [PPPOE_NIC=eth1] lxc/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
: "${PPPOE_USER:?}" "${PPPOE_PASS:?}"
NIC=${PPPOE_NIC:-eth1}
VER=$(awk -F: '/image: ghcr.io\/sagernet\/sing-box/ {sub(/^v/, "", $NF); print $NF; exit}' compose.yaml)
ARCH=$(dpkg --print-architecture)

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ppp curl openssl ca-certificates >/dev/null
if [ "$(sing-box version 2>/dev/null | awk 'NR==1 {print $3}')" != "$VER" ]; then
  deb=$(mktemp -d)/sing-box.deb
  curl -fsSL -o "$deb" "https://github.com/SagerNet/sing-box/releases/download/v$VER/sing-box_${VER}_linux_${ARCH}.deb"
  dpkg -i "$deb" >/dev/null; rm -f "$deb"
fi

# PPPoE
sed -e "s/ens19/$NIC/g" -e "s/^user .*/user \"$PPPOE_USER\"/" pppoe/hinet.peer > /etc/ppp/peers/hinet
for f in chap-secrets pap-secrets; do
  sed -i "/\"$PPPOE_USER\"/d" /etc/ppp/$f
  echo "\"$PPPOE_USER\" * \"$PPPOE_PASS\" *" >> /etc/ppp/$f
  chmod 600 /etc/ppp/$f
done
install -m 755 pppoe/ip-up.10-hy2vpn-route   /etc/ppp/ip-up.d/10-hy2vpn-route
install -m 755 pppoe/ip-down.10-hy2vpn-route /etc/ppp/ip-down.d/10-hy2vpn-route
install -m 755 pppoe/ip-up.20-duckdns        /etc/ppp/ip-up.d/20-duckdns
sed "s#__HY2VPN_ENV__#$ROOT/.env#" pppoe/duckdns-update > /usr/local/sbin/hy2vpn-duckdns
chmod 755 /usr/local/sbin/hy2vpn-duckdns
sed "s/ens19/$NIC/g" pppoe/pppoe-hinet.service > /etc/systemd/system/pppoe-hinet.service
install -m 644 lxc/duckdns.service lxc/duckdns.timer /etc/systemd/system/

# sing-box 讀 /etc/sing-box，直接指到 repo 裡的設定
if [ ! -L /etc/sing-box ]; then rm -rf /etc/sing-box; ln -s "$ROOT/sing-box" /etc/sing-box; fi
grep -q '^CONTAINER_CLI=' .env && sed -i 's/^CONTAINER_CLI=.*/CONTAINER_CLI=native/' .env || echo CONTAINER_CLI=native >> .env
[ -f sing-box/config.json ] || scripts/setup.sh
sing-box check -c /etc/sing-box/config.json

# BBR（LXC 的 network namespace 可以各自設定；default_qdisc 不行，略過）
echo 'net.ipv4.tcp_congestion_control = bbr' > /etc/sysctl.d/99-vpn.conf
sysctl -q -p /etc/sysctl.d/99-vpn.conf || echo "BBR 沒開成，主機要先 modprobe tcp_bbr"

systemctl daemon-reload
systemctl enable --now pppoe-hinet duckdns.timer
systemctl enable sing-box && systemctl restart sing-box
echo "完成。確認：ip -br addr show ppp0; systemctl status sing-box"
