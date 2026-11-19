#!/usr/bin/env bash
# Linux 主機調校：TCP BBR（幫 Reality）＋放大 UDP buffer（幫 Hysteria 2 / QUIC）。
# 寫在 /etc/sysctl.d/ 獨立檔案，可以重複執行，不會一直往 sysctl.conf 疊加。
set -euo pipefail
[ "$(uname -s)" = Linux ] || { echo "這支只給 Linux 主機用" >&2; exit 1; }

sudo tee /etc/sysctl.d/99-vpn.conf >/dev/null <<'CONF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
CONF
sudo modprobe tcp_bbr 2>/dev/null || true
sudo sysctl --system >/dev/null
echo "congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "rmem_max: $(sysctl -n net.core.rmem_max)"
