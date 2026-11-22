#!/usr/bin/env bash
# 在 PVE 主機上建立跑 hy2vpn 的 LXC（unprivileged）。
# 不指定 DNS 的話 LXC 會繼承主機的 resolv.conf，主機裝了 Tailscale 時會拿到連不到的 100.100.100.100
# 用法：CTID=107 SSH_KEY=~/.ssh/id_ed25519.pub [LAN_BRIDGE=vmbr0] [WAN_BRIDGE=vmbr1] lxc/create-ct.sh
#   LAN_BRIDGE：區網，拿來管理
#   WAN_BRIDGE：直通數據機，拿來撥 PPPoE（在 PVE 上用 bridge fdb show | grep <數據機 MAC> 找）
set -euo pipefail
: "${CTID:?}" "${SSH_KEY:?}"
LAN=${LAN_BRIDGE:-vmbr0}; WAN=${WAN_BRIDGE:-vmbr1}
TEMPLATE=${TEMPLATE:-ubuntu-26.04-standard_26.04-1_amd64.tar.zst}

# PPPoE 和 BBR 都要用主機的核心模組，LXC 裡面沒辦法自己載
printf 'ppp_generic\npppox\npppoe\ntcp_bbr\n' > /etc/modules-load.d/ppp.conf
modprobe -a ppp_generic pppox pppoe tcp_bbr

[ -f "/var/lib/vz/template/cache/$TEMPLATE" ] || { pveam update >/dev/null; pveam download local "$TEMPLATE"; }

pct create "$CTID" "local:vztmpl/$TEMPLATE" \
  --hostname "${HOSTNAME_CT:-hy2vpn}" --unprivileged 1 --features nesting=1 \
  --cores 2 --memory 512 --swap 512 --rootfs local-lvm:4 \
  --net0 name=eth0,bridge="$LAN",ip=dhcp,type=veth \
  --net1 name=eth1,bridge="$WAN",ip=manual,type=veth \
  --dev0 /dev/ppp,mode=0600 \
  --nameserver "${NAMESERVER:-1.1.1.1 8.8.8.8}" \
  --onboot 1 --ssh-public-keys "$SSH_KEY" --timezone "${TZ_CT:-Asia/Taipei}"
pct start "$CTID"
echo "LXC $CTID 已啟動。接著把 repo 放進去，在裡面執行 lxc/install.sh"
