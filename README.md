# 今天蹬了多少 Token

一個網頁，顯示你今天用 Claude Code 和 Codex 蹬了多少 token、等值多少 API 費用、大概耗掉多少電，還可以回頭看每一天的日報。

數據來自 [ccusage](https://github.com/ryoppippi/ccusage)，全部在你自己的電腦上計算，不會上傳到任何地方。

## 功能

- **今天的總量**：超大數字、Claude Code／Codex 各佔多少、API 等值花費
- **各工具明細**：讀取快取／輸入／輸出／寫入快取各多少、用了哪些模型
- **電費估算**：用公開研究的係數粗估耗電（度）與電費，預設台電平均電價
- **正在蹬**：偵測 Claude Code／Codex 現在有沒有在跑、同時開了幾個工作階段
- **最近幾天**：右邊列出最近每一天的用量，依畫面高度自動決定顯示幾天
- **每日報表**：點最近幾天裡的任何一天，整頁換成那天的日報
  - 跟前一天比、跟前 7 天平均比、在最近 60 天裡排第幾高
  - 網址會變成 `…/#2026-11-16`，重新整理或傳給別人都會停在那天
  - 「日報圖片」把那天畫成一張台灣電子發票樣式的圖：上面是「電子蹬票證明聯」（期別、字軌號碼、條碼、兩個 QR Code），下面是交易明細（各工具與模型、總量、花費、電費、比較、最近 14 天走勢）。左邊的 QR Code 掃出來是這天的摘要，右邊是這個專案的網址。可以直接貼到聊天室或下載。用 https 或 `localhost` 開時按下去就會複製到剪貼簿；用區網 IP（`http://192.168…`）開的話瀏覽器不允許網頁直接寫入剪貼簿，在圖片上按右鍵「複製圖片」（手機長按）就好
  - 按 `Esc` 或「回到今天」回來
- 手機、深色模式都能看；適合掛在一台螢幕上常駐顯示

## 一鍵部署

在**平常用 Claude Code／Codex 的那台電腦**上，用**你自己的帳號**執行（不要加 sudo）：

```bash
curl -fsSL https://raw.githubusercontent.com/Zhuyuan0907/today-use-token/main/install.sh | bash
```

或是先 clone 再裝：

```bash
git clone https://github.com/Zhuyuan0907/today-use-token.git
cd today-use-token
./install.sh
```

腳本會自動：

1. 檢查 Node.js 20 以上；沒有的話下載一份放在專案的 `.node/` 裡（不會動到系統）
2. 在專案裡安裝 ccusage（不用全域安裝）
3. 找一個空的 port（預設 3000，被佔用就自動往後找）
4. Linux 有 systemd 的話裝成系統服務，開機自動啟動、掛掉自動重啟；沒有 systemd（macOS、沒開 systemd 的 WSL…）就用背景程式跑
5. 確認網頁真的連得上、讀得到數據，最後印出要連的網址和 port：

```
==> 完成！打開瀏覽器連到：

    這台電腦   http://localhost:3000
    區網       http://192.168.1.23:3000    (eth0)
    外網       http://203.0.113.5:3000    (要在路由器設 port forwarding，或在雲端主機的防火牆開放 3000)

    Port：3000
```

> **為什麼一定要在那台電腦上跑？** Claude Code 和 Codex 會把每次對話（包含 token 用量）記在本機的 `~/.claude`、`~/.codex`，ccusage 就是讀這些檔案。如果你在好幾台電腦上用，每台只看得到自己那台的用量。

支援 Linux、macOS（x64／arm64）；Windows 請在 WSL 裡跑。

### 指定 port、時區

```bash
PORT=8080 ./install.sh
TZ_NAME=Asia/Taipei ./install.sh
```

主機時區是 UTC 的話（很多雲端主機都是），在台灣請一定要設 `TZ_NAME=Asia/Taipei`，不然「今天」會從早上 8 點才開始算。

這些設定會記在專案的 `.env`，之後重跑 `install.sh`（例如更新）會沿用；想改就編輯 `.env` 再跑一次。

### 更新、移除

```bash
cd today-use-token && git pull && ./install.sh   # 更新（用 curl 裝的就再跑一次那行 curl）
./install.sh uninstall                           # 停止並移除服務（程式資料夾和你的紀錄都不會刪）
```

用 systemd 跑的話：

```bash
systemctl status today-use-token        # 看狀態
journalctl -u today-use-token -f        # 看 log
sudo systemctl restart today-use-token  # 重新啟動
```

### 其他電腦連不進來？

- 確認兩台在同一個網路，用腳本印出來的「區網」網址連
- 有開防火牆的話要開放那個 port（腳本偵測到 ufw／firewalld 會提示指令），例如 `sudo ufw allow 3000/tcp`
- 雲端主機要在主機商的安全群組／防火牆開放那個 port

## 設定

全部用環境變數設定，`install.sh` 會記在 `.env`：

| 變數 | 預設 | 說明 |
|---|---|---|
| `PORT` | `3000` | 網頁的 port |
| `HOST` | `0.0.0.0` | 只想自己這台看的話設成 `127.0.0.1` |
| `TZ_NAME` | 系統時區 | 「今天」用哪個時區算，例如 `Asia/Taipei` |
| `KWH_PRICE` | `3.7823` | 每度電多少錢（預設台電 2026 年平均電價） |
| `KWH_CURRENCY` | `NT$` | 電費的貨幣符號 |
| `ACTIVE_SECONDS` | `120` | 紀錄檔幾秒內有更新就算「正在蹬」 |
| `CLAUDE_CONFIG_DIR` | `~/.config/claude`、`~/.claude` | Claude Code 的資料夾，多個用逗號分隔 |
| `CODEX_HOME` | `~/.codex` | Codex 的資料夾 |
| `CCUSAGE_BIN` | 專案內的 ccusage | 想改用別的 ccusage 執行檔才需要設 |

只有 `install.sh` 用的：

| 變數 | 預設 | 說明 |
|---|---|---|
| `INSTALL_DIR` | `~/today-use-token` | 用 curl 一行安裝時，程式放在哪裡 |
| `SERVICE_NAME` | `today-use-token` | systemd 服務的名稱（同一台想跑兩份時用） |
| `NO_SYSTEMD` | | 設成 `1` 就不裝 systemd 服務、改用背景程式（例如沒有 sudo 權限時） |

## 不用腳本，自己跑

需要 Node.js 20 以上：

```bash
npm install
node server.js
# 或：PORT=8080 TZ_NAME=Asia/Taipei node server.js
```

## API

- `GET /api/usage`：最近 60 天每天的用量（各工具、各模型、花費、耗電）。ccusage 跑一次要幾秒，結果會快取 1 分鐘；加 `?fresh` 強制重抓。
- `GET /api/status`：Claude Code／Codex 現在有沒有在跑、同時幾個工作階段。

## 電費是怎麼估的

各類 token（輸入、輸出、寫入快取、讀取快取）數量 × 每 100 萬 token 的耗電係數。係數有樂觀／中間／保守三組，出處寫在 `server.js` 的註解裡，網頁上顯示中間值，滑鼠移到耗電數字上可以看到係數。這只是數量級的粗估，不是實際的帳單。

## 安全提醒

網頁沒有登入功能：知道網址的人都看得到你的用量、花費，以及你什麼時候在用。建議只在家裡或公司的區網、或透過 Tailscale 之類的 VPN 連線；真的要放到外網，請在前面加一層需要帳號密碼的反向代理（例如 Caddy／Nginx 的 basic auth、Cloudflare Access）。

## 授權

[MIT](LICENSE)
