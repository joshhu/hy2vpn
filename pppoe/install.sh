#!/usr/bin/env bash
# 在 Ubuntu VM 上設定 PPPoE 撥號（中華電信光世代動態 IP）。
# 前提：VM 有第二張網卡（預設 ens19）接在能直通數據機的 bridge 上。
# 用法：sudo PPPOE_USER=12345678@hinet.net PPPOE_PASS=xxxx [PPPOE_NIC=ens19] pppoe/install.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${PPPOE_USER:?}" "${PPPOE_PASS:?}"
NIC=${PPPOE_NIC:-ens19}
apt-get install -y -qq ppp >/dev/null

sed "s/ens19/$NIC/g" 60-hy2vpn.yaml > /etc/netplan/60-hy2vpn.yaml && chmod 600 /etc/netplan/60-hy2vpn.yaml
sed -e "s/ens19/$NIC/g" -e "s/^user .*/user \"$PPPOE_USER\"/" hinet.peer > /etc/ppp/peers/hinet
for f in chap-secrets pap-secrets; do
  sed -i "/\"$PPPOE_USER\"/d" /etc/ppp/$f
  echo "\"$PPPOE_USER\" * \"$PPPOE_PASS\" *" >> /etc/ppp/$f
  chmod 600 /etc/ppp/$f
done
install -m 755 ip-up.10-hy2vpn-route   /etc/ppp/ip-up.d/10-hy2vpn-route
install -m 755 ip-down.10-hy2vpn-route /etc/ppp/ip-down.d/10-hy2vpn-route
install -m 755 ip-up.20-duckdns        /etc/ppp/ip-up.d/20-duckdns
sed "s#__HY2VPN_ENV__#$(cd .. && pwd)/.env#" duckdns-update > /usr/local/sbin/hy2vpn-duckdns
chmod 755 /usr/local/sbin/hy2vpn-duckdns
sed "s/ens19/$NIC/g" pppoe-hinet.service > /etc/systemd/system/pppoe-hinet.service

netplan apply
systemctl daemon-reload
systemctl enable --now pppoe-hinet
echo "等 ppp0 上線：ip -br addr show ppp0"
