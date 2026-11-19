#!/usr/bin/env bash
# 檢查 Reality 偽裝目標是否支援 TLS 1.3 + HTTP/2，並量 TLS 握手時間。
# 請在「伺服器主機」上執行，量到的才是主機到目標的距離。需要 openssl 和 curl。
# 用法：scripts/check-target.sh www.example.com [更多網域…]
set -uo pipefail
[ $# -gt 0 ] || { echo "用法：$0 <網域> [網域…]" >&2; exit 1; }
for host in "$@"; do
  info=$(echo | timeout 8 openssl s_client -connect "$host:443" -servername "$host" \
         -tls1_3 -alpn h2 2>/dev/null)
  if echo "$info" | grep -q 'TLSv1.3'; then tls13=✓; else tls13=✗; fi
  if echo "$info" | grep -q 'ALPN protocol: h2'; then h2=✓; else h2=✗; fi
  ms=$(curl -s -o /dev/null --max-time 8 -w '%{time_connect} %{time_appconnect}' "https://$host/" \
       | awk '{printf "%.0f", ($2-$1)*1000}')
  ok=OK; [ "$tls13$h2" = ✓✓ ] || ok=不能用
  printf '%-28s TLS1.3 %s  h2 %s  TLS 握手 %4sms  → %s\n' "$host" "$tls13" "$h2" "${ms:-?}" "$ok"
done
