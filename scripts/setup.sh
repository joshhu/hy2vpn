#!/usr/bin/env bash
# 產生金鑰、自簽憑證、sing-box 伺服器設定與客戶端分享連結。
# 可以重複執行：金鑰第一次產生後存在 .state/，之後沿用，只會重新渲染設定。
# 要換掉所有金鑰：rm -rf .state sing-box/hy2.* 後再執行。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

[ -f .env ] || { echo "找不到 .env，先執行：cp .env.example .env 再編輯" >&2; exit 1; }
set -a; . ./.env; set +a

: "${SERVER_DOMAIN:?SERVER_DOMAIN 未設定}"
REALITY_PORT=${REALITY_PORT:-443}
REALITY_TARGET=${REALITY_TARGET:-www.microsoft.com}
HY2_PORT=${HY2_PORT:-443}
HY2_MASQUERADE=${HY2_MASQUERADE:-https://www.bing.com}
# hy2 自簽憑證的名稱與客戶端 SNI。預設用偽裝網站的主機名，伺服器填 IP 時也能通過憑證驗證
HY2_SNI=${HY2_SNI:-$(echo "$HY2_MASQUERADE" | sed -E "s#^[a-z]+://##; s#[/:].*##")}
LISTEN_ADDR=${LISTEN_ADDR:-::}
CLI=${CONTAINER_CLI:-docker}
IMG=$(awk '/image: ghcr.io\/sagernet\/sing-box/ {print $2; exit}' compose.yaml)

sb() { "$CLI" run --rm "$IMG" "$@" 2>/dev/null; }

mkdir -p .state sing-box client
chmod 700 .state client
STATE=.state/keys.env

if [ ! -f "$STATE" ]; then
  echo "第一次執行，產生金鑰…"
  kp=$(sb generate reality-keypair)
  {
    echo "UUID=$(sb generate uuid | tr -d '\r\n')"
    echo "REALITY_PRIVATE_KEY=$(echo "$kp" | awk '/PrivateKey/ {print $2}')"
    echo "REALITY_PUBLIC_KEY=$(echo "$kp" | awk '/PublicKey/ {print $2}')"
    echo "SHORT_ID=$(sb generate rand --hex 8 | tr -d '\r\n')"
    echo "HY2_PASSWORD=$(sb generate rand --hex 16 | tr -d '\r\n')"
  } > "$STATE"
  chmod 600 "$STATE"
fi
. "$STATE"
for v in UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY SHORT_ID HY2_PASSWORD; do
  [ -n "${!v:-}" ] || { echo "$STATE 裡的 $v 是空的，刪掉 .state 重跑" >&2; exit 1; }
done

# Hysteria 2 自簽憑證（10 年）。網域改了就重簽。
if [ ! -f sing-box/hy2.crt ] || [ "$(cat .state/hy2.cn 2>/dev/null)" != "${HY2_SNI}" ]; then
  echo "產生 Hysteria 2 自簽憑證（CN=${HY2_SNI}）…"
  pem=$(sb generate tls-keypair "${HY2_SNI}" --months 120)
  echo "$pem" | sed -n '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/p' > sing-box/hy2.key
  echo "$pem" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > sing-box/hy2.crt
  chmod 600 sing-box/hy2.key; chmod 644 sing-box/hy2.crt
  echo "${HY2_SNI}" > .state/hy2.cn
fi

if [ -n "${HY2_UP_MBPS:-}" ] && [ -n "${HY2_DOWN_MBPS:-}" ]; then
  HY2_BW="\"up_mbps\": $HY2_UP_MBPS, \"down_mbps\": $HY2_DOWN_MBPS,"
  CC_NOTE="Brutal（上傳 ${HY2_UP_MBPS} / 下載 ${HY2_DOWN_MBPS} Mbps）"
else
  HY2_BW=""
  CC_NOTE="BBR"
fi

cat > sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "$LISTEN_ADDR",
      "listen_port": $REALITY_PORT,
      "users": [ { "name": "me", "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_TARGET",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_TARGET", "server_port": 443 },
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": [ "$SHORT_ID" ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "$LISTEN_ADDR",
      "listen_port": $HY2_PORT,
      $HY2_BW
      "users": [ { "name": "me", "password": "$HY2_PASSWORD" } ],
      "masquerade": { "type": "proxy", "url": "$HY2_MASQUERADE", "rewrite_host": true },
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "/etc/sing-box/hy2.crt",
        "key_path": "/etc/sing-box/hy2.key"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "final": "direct" }
}
EOF
chmod 644 sing-box/config.json

echo "檢查設定…"
"$CLI" run --rm -v "$ROOT/sing-box:/etc/sing-box:ro" "$IMG" check -c /etc/sing-box/config.json

# ---------- 客戶端 ----------
PIN=""
if command -v openssl >/dev/null 2>&1; then
  PIN=$(openssl x509 -in sing-box/hy2.crt -noout -fingerprint -sha256 | cut -d= -f2)
fi
CERT_JSON=$(awk 'BEGIN{ORS=""; print "["} {if (NR>1) print ", "; printf "\"%s\"", $0} END{print "]"}' sing-box/hy2.crt)

VLESS_LINK="vless://$UUID@$SERVER_DOMAIN:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_TARGET&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$SHORT_ID&type=tcp#home-reality"
if [ -n "$PIN" ]; then
  HY2_LINK="hysteria2://$HY2_PASSWORD@$SERVER_DOMAIN:$HY2_PORT/?sni=$HY2_SNI&insecure=1&pinSHA256=$PIN#home-hy2"
else
  HY2_LINK="hysteria2://$HY2_PASSWORD@$SERVER_DOMAIN:$HY2_PORT/?sni=$HY2_SNI&insecure=1#home-hy2"
fi
printf '%s\n%s\n' "$VLESS_LINK" "$HY2_LINK" > client/links.txt

# sing-box 客戶端（SFM / SFI / SFA / 桌面 sing-box）：hy2 直接信任這張自簽憑證，不用 insecure
cat > client/sing-box-client.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080 }
  ],
  "outbounds": [
    { "type": "selector", "tag": "proxy", "outbounds": [ "home-reality", "home-hy2" ], "default": "home-reality" },
    {
      "type": "vless",
      "tag": "home-reality",
      "server": "$SERVER_DOMAIN",
      "server_port": $REALITY_PORT,
      "uuid": "$UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_TARGET",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "$REALITY_PUBLIC_KEY", "short_id": "$SHORT_ID" }
      }
    },
    {
      "type": "hysteria2",
      "tag": "home-hy2",
      "server": "$SERVER_DOMAIN",
      "server_port": $HY2_PORT,
      "password": "$HY2_PASSWORD",
      "tls": {
        "enabled": true,
        "server_name": "$HY2_SNI",
        "alpn": [ "h3" ],
        "certificate": $CERT_JSON
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "proxy" }
}
EOF
chmod 600 client/links.txt client/sing-box-client.json

cat <<EOF

完成。
  伺服器設定：sing-box/config.json
  Reality：TCP ${REALITY_PORT}，偽裝目標 $REALITY_TARGET
  Hysteria 2：UDP ${HY2_PORT}，擁塞控制 $CC_NOTE
  hy2 憑證 SHA-256：${PIN:-（沒有 openssl，算不出來；分享連結會缺 pinSHA256）}

分享連結（client/links.txt，等同密碼，別貼到公開的地方）：
$VLESS_LINK
$HY2_LINK

sing-box 客戶端完整設定：client/sing-box-client.json
下一步：docker compose --profile duckdns up -d   （或 --profile cloudflare）
EOF
