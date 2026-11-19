# hy2vpn

在自己有公網 IP 的 Linux 主機上，用 Docker 跑 [sing-box](https://github.com/SagerNet/sing-box)，同時提供兩條翻牆線路：

| 線路 | 傳輸 | 用途 |
|---|---|---|
| **VLESS + XTLS-Vision + Reality** | TCP 443 | 主力。被探測時回應的是偽裝目標網站的真實憑證，抗封鎖能力最強 |
| **Hysteria 2** | UDP 443 | 備用。線路丟包嚴重時速度較好，但 UDP 容易被電信商限速 |

不需要網域，也不需要 Let's Encrypt：Reality 借用偽裝目標網站的憑證，hy2 用自簽憑證，客戶端直接釘選它的指紋或信任這張憑證。

## 需求

- Linux 主機，有公網 IP（固定、浮動都可以；浮動 IP 搭配內建的 DDNS 容器）
- Docker 與 Docker Compose v2
- `openssl`（用來算 hy2 憑證指紋）、`curl`

## 部署

```bash
cp .env.example .env
vi .env                         # 至少填 SERVER_DOMAIN；固定 IP 直接填 IP

scripts/check-target.sh www.asus.com www.microsoft.com   # 在主機上挑 Reality 偽裝目標
scripts/setup.sh                # 產生金鑰、憑證、伺服器設定、客戶端連結
scripts/host-tune.sh            # 開 BBR、放大 UDP buffer（需要 sudo）
docker compose up -d            # 浮動 IP 改用：docker compose --profile duckdns up -d
```

`setup.sh` 可以重複執行：金鑰存在 `.state/`，之後都會沿用，只重新渲染設定。改完 `.env` 重跑一次，再 `docker compose restart` 就生效。

要換掉所有金鑰（例如連結外流）：

```bash
rm -rf .state sing-box/hy2.* && scripts/setup.sh && docker compose restart
```

### 防火牆

compose 使用 `network_mode: host`，Docker 不會幫你開埠。主機有開 ufw 的話：

```bash
sudo ufw allow 443/tcp && sudo ufw allow 443/udp
```

主機在分享器後面的話，記得把 TCP/UDP 443 轉發到這台機器。

## 客戶端

`setup.sh` 會在 `client/` 產生：

- `links.txt`：`vless://` 與 `hysteria2://` 分享連結
- `sing-box-client.json`：sing-box 客戶端完整設定，兩個節點用 selector 切換，hy2 直接信任自簽憑證

| 平台 | App | 匯入 |
|---|---|---|
| iOS / iPadOS | sing-box (SFI)、Shadowrocket | JSON，或掃 QR Code |
| macOS | sing-box (SFM)、Clash Verge Rev | JSON，或貼連結 |
| Android | v2rayNG、sing-box (SFA)、Hiddify | 貼連結，或掃 QR Code |
| Windows | v2rayN、Hiddify | 貼連結 |

產生 QR Code：

```bash
uvx --from 'qrcode[pil]' qr --output qr.png "$(sed -n 1p client/links.txt)"
```

`client/` 裡的東西等同密碼，不要傳到公開的地方。

## 從中國使用的建議

- **主力用 Reality，hy2 只在 Reality 跑不動時短暫切換。** 大量往境外的 UDP 容易被限速，也容易讓 IP 被盯上。
- **不要開 Brutal**（`HY2_UP_MBPS` / `HY2_DOWN_MBPS` 留空，使用 BBR）。
- **偽裝目標選離主機近、在中國沒被封的網站**，先用 `check-target.sh` 確認支援 TLS 1.3 與 h2。
- **出發前在台灣就把 App 裝好、連線測過。** 中國區 App Store 沒有這些 App，Google Play 在中國也連不上。
- 固定 IP 被封鎖後沒辦法靠重撥換 IP，所以不要分享給太多人用。

## 檔案

```
compose.yaml            sing-box + 兩個可選的 DDNS 容器（duckdns / cloudflare profile）
.env.example            所有可調參數
scripts/setup.sh        產生金鑰、憑證、設定與客戶端連結
scripts/check-target.sh 檢查 Reality 偽裝目標
scripts/host-tune.sh    BBR 與 UDP buffer 調校
```

所有產生出來的檔案（`.env`、`.state/`、`sing-box/config.json`、`sing-box/hy2.*`、`client/`）都已經寫進 `.gitignore`。
