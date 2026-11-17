#!/usr/bin/env bash
# 今天蹬了多少 Token —— 一鍵部署
#
#   ./install.sh                安裝或更新，在背景啟動（有 systemd 的話開機會自動啟動）
#   PORT=8080 ./install.sh      指定 port（預設 3000，被佔用會自動往後找空的）
#   ./install.sh uninstall      停止並移除背景服務（程式和你的數據都不會刪）
#
# 不想先 clone 的話，一行搞定（會裝到 ~/today-use-token）：
#   curl -fsSL https://raw.githubusercontent.com/Zhuyuan0907/today-use-token/main/install.sh | bash
#
# 請在「平常用 Claude Code／Codex 的那台電腦、那個帳號」執行，不要加 sudo：
# 數據是從這個帳號的 ~/.claude、~/.codex 讀的，需要 root 權限的步驟腳本會自己用 sudo。

set -euo pipefail

REPO="Zhuyuan0907/today-use-token"
SERVICE="${SERVICE_NAME:-today-use-token}"
UNIT="/etc/systemd/system/$SERVICE.service"
NODE_VERSION="v24.22.3" # 系統沒有 Node 20 以上時，下載這版放進專案的 .node/（不動系統）
MIN_NODE_MAJOR=20
DEFAULT_PORT=3000
# 會記在 .env 的設定：下次重跑腳本（例如更新）會沿用；執行時用環境變數給的值優先
CONFIG_KEYS=(PORT HOST TZ_NAME KWH_PRICE KWH_CURRENCY ACTIVE_SECONDS CLAUDE_CONFIG_DIR CODEX_HOME CCUSAGE_BIN)

if [ -t 1 ]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' D=$'\e[2m' N=$'\e[0m'; else B='' G='' Y='' R='' D='' N=''; fi
say() { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$B" "$N" "$*"; }
warn() { printf '%s注意：%s%s\n' "$Y" "$*" "$N" >&2; }
die() { printf '%s錯誤：%s%s\n' "$R" "$*" "$N" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [ "$(id -u)" -eq 0 ]; }
as_root() { if is_root; then "$@"; else sudo "$@"; fi; }
as_root_quiet() { if is_root; then "$@"; else sudo -n "$@"; fi; } # 不跳出密碼提示，只用來查狀態

fetch() { # fetch <網址> <存檔位置>
  if have curl; then
    curl -fsSL --retry 2 -o "$2" "$1"
  elif have wget; then
    wget -q -O "$2" "$1"
  else
    die "需要 curl 或 wget 才能下載"
  fi
}

# ---------- 程式放哪 ----------

resolve_app_dir() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [ -n "$here" ] && [ -f "$here/server.js" ] && [ -f "$here/public/index.html" ]; then
    APP_DIR="$here" # 在 clone 下來的資料夾裡執行
    FROM_CHECKOUT=1
  else
    APP_DIR="${INSTALL_DIR:-$HOME/today-use-token}" # curl | bash
    FROM_CHECKOUT=0
  fi
}

fetch_app() {
  [ "$FROM_CHECKOUT" = 1 ] && return 0
  if [ -d "$APP_DIR/.git" ]; then
    step "更新 $APP_DIR"
    git -C "$APP_DIR" pull --ff-only
  elif [ -e "$APP_DIR" ] && [ ! -f "$APP_DIR/server.js" ]; then
    die "$APP_DIR 已經存在但不是這個專案；用 INSTALL_DIR=其他位置 指定別的資料夾"
  elif have git && [ ! -e "$APP_DIR" ]; then
    step "下載程式到 $APP_DIR"
    git clone --depth 1 "https://github.com/$REPO.git" "$APP_DIR"
  else
    step "下載程式到 $APP_DIR"
    local tmp
    tmp="$(mktemp -d)"
    fetch "https://github.com/$REPO/archive/refs/heads/main.tar.gz" "$tmp/src.tgz"
    mkdir -p "$APP_DIR"
    tar -xzf "$tmp/src.tgz" -C "$APP_DIR" --strip-components 1
    rm -rf "$tmp"
  fi
}

# ---------- 設定（.env） ----------

load_config() {
  local file="$APP_DIR/.env" line key val k
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | \#*) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    val="${val#\'}"
    val="${val%\'}"
    if [ "$key" = PORT ]; then PREV_PORT="$val"; fi
    for k in "${CONFIG_KEYS[@]}"; do
      if [ "$k" = "$key" ] && [ -z "${!k:-}" ]; then printf -v "$k" '%s' "$val"; fi
    done
  done <"$file"
}

write_config() {
  local k
  {
    say "# install.sh 產生的設定。改完重跑 ./install.sh（或重新啟動服務）就會生效。"
    for k in "${CONFIG_KEYS[@]}"; do
      if [ -n "${!k:-}" ]; then say "$k='${!k}'"; fi
    done
  } >"$APP_DIR/.env"
}

# ---------- Node.js ----------

node_major() { "$1" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }

ensure_node() {
  NODE_BIN=""
  local sys
  sys="$(command -v node || true)"
  if [ -n "$sys" ] && [ "$(node_major "$sys")" -ge "$MIN_NODE_MAJOR" ] && [ -x "$(dirname "$sys")/npm" ]; then
    NODE_BIN="$sys"
  elif [ -x "$APP_DIR/.node/bin/node" ]; then
    NODE_BIN="$APP_DIR/.node/bin/node" # 之前下載過
  else
    local os arch tmp
    case "$(uname -s)" in
      Linux) os=linux ;;
      Darwin) os=darwin ;;
      *) die "不支援這個系統：$(uname -s)（Windows 請用 WSL）" ;;
    esac
    case "$(uname -m)" in
      x86_64 | amd64) arch=x64 ;;
      aarch64 | arm64) arch=arm64 ;;
      *) die "不支援這種 CPU：$(uname -m)（ccusage 只有 x64 和 arm64 版）" ;;
    esac
    step "這台沒有 Node.js $MIN_NODE_MAJOR 以上，下載 Node $NODE_VERSION 到 $APP_DIR/.node（不會動到系統）"
    tmp="$(mktemp -d)"
    fetch "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-$os-$arch.tar.gz" "$tmp/node.tgz"
    rm -rf "$APP_DIR/.node"
    mkdir -p "$APP_DIR/.node"
    tar -xzf "$tmp/node.tgz" -C "$APP_DIR/.node" --strip-components 1
    rm -rf "$tmp"
    NODE_BIN="$APP_DIR/.node/bin/node"
  fi
  NODE_DIR="$(dirname "$NODE_BIN")"
  say "    Node $("$NODE_BIN" -v)  ${D}$NODE_BIN${N}"
}

install_deps() {
  step "安裝 ccusage（裝在專案的 node_modules 裡，不用全域安裝）"
  (cd "$APP_DIR" && PATH="$NODE_DIR:$PATH" "$NODE_DIR/npm" ci --omit=dev --no-audit --no-fund --loglevel=error)
  say "    ccusage $("$NODE_BIN" -p 'require(process.argv[1]).version' "$APP_DIR/node_modules/ccusage/package.json")"
}

# ---------- 檢查有沒有數據可讀 ----------

check_data() {
  local dirs=() d claude=0 codex=0
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    IFS=, read -ra dirs <<<"$CLAUDE_CONFIG_DIR"
  else
    dirs=("$HOME/.config/claude" "$HOME/.claude")
  fi
  for d in "${dirs[@]}"; do
    if [ -d "$d/projects" ]; then claude=1; fi
  done
  if [ -d "${CODEX_HOME:-$HOME/.codex}/sessions" ]; then codex=1; fi
  if [ "$claude" = 0 ] && [ "$codex" = 0 ]; then
    warn "在 $HOME 底下找不到 Claude Code（~/.claude）或 Codex（~/.codex）的紀錄，網頁會一直是 0。"
    warn "請確認是用「平常跑 Claude Code／Codex 的帳號」執行這個腳本。"
  else
    say "    找到紀錄：Claude Code $([ "$claude" = 1 ] && echo ✓ || echo ✗)　Codex $([ "$codex" = 1 ] && echo ✓ || echo ✗)"
  fi
  local tz
  tz="$("$NODE_BIN" -p 'Intl.DateTimeFormat().resolvedOptions().timeZone' 2>/dev/null || echo UTC)"
  if [ -z "${TZ_NAME:-}" ] && { [ "$tz" = UTC ] || [ "$tz" = Etc/UTC ]; }; then
    warn "這台的時區是 UTC，「今天」會從台灣時間早上 8 點才開始算。在台灣的話這樣裝：TZ_NAME=Asia/Taipei ./install.sh"
  fi
}

# ---------- 背景服務 ----------

use_systemd() {
  [ "${NO_SYSTEMD:-}" = 1 ] && return 1
  [ "$(uname -s)" = Linux ] && have systemctl && [ -d /run/systemd/system ] || return 1
  is_root || have sudo
}

bg_pid() { # 用 NO_SYSTEMD 方式跑起來的 PID（確定還活著而且是我們的才回傳）
  local pid
  pid="$(cat "$APP_DIR/.server.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= 2>/dev/null | grep -q server.js && echo "$pid"
}

stop_existing() {
  if [ -f "$UNIT" ]; then as_root systemctl stop "$SERVICE" 2>/dev/null || true; fi
  local pid i
  pid="$(bg_pid || true)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    for ((i = 0; i < 50; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  fi
  rm -f "$APP_DIR/.server.pid"
}

port_free() {
  "$NODE_BIN" -e '
    const s = require("net").createServer();
    s.once("error", () => process.exit(1));
    s.listen(+process.argv[1], process.argv[2], () => s.close(() => process.exit(0)));' "$1" "${HOST:-0.0.0.0}" 2>/dev/null
}

check_port_number() {
  case "$1" in '' | *[!0-9]*) die "PORT 要是數字：$1" ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "PORT 要在 1–65535 之間：$1"
}

# 指定的 port 如果不是自己上次用的，先確認空著再停掉舊的，免得舊的停了新的又起不來
precheck_port() {
  [ -n "$PORT_ARG" ] || return 0
  check_port_number "$PORT_ARG"
  if [ "$PORT_ARG" != "${PREV_PORT:-}" ] && ! port_free "$PORT_ARG"; then
    die "port $PORT_ARG 已經被別的程式佔用了，換一個：PORT=其他數字 ./install.sh"
  fi
}

choose_port() {
  local start="${PORT:-$DEFAULT_PORT}" i
  check_port_number "$start"
  if [ -n "$PORT_ARG" ]; then
    port_free "$start" || die "port $start 已經被別的程式佔用了，換一個：PORT=其他數字 ./install.sh"
    PORT="$start"
    return
  fi
  for ((i = 0; i < 50 && start + i <= 65535; i++)); do
    if port_free $((start + i)); then
      PORT=$((start + i))
      if [ "$i" -gt 0 ]; then warn "port $start 被別的程式佔用了，改用 $PORT"; fi
      return
    fi
  done
  die "從 $start 往後 50 個 port 都被佔用了，用 PORT=其他數字 ./install.sh 指定一個"
}

service_path() {
  case "$NODE_DIR" in
    /usr/local/bin | /usr/bin | /bin) echo "/usr/local/bin:/usr/bin:/bin" ;;
    *) echo "$NODE_DIR:/usr/local/bin:/usr/bin:/bin" ;;
  esac
}

start_systemd() {
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
[Unit]
Description=today-use-token（今天蹬了多少 Token）
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$APP_DIR
Environment="HOME=$HOME"
Environment="PATH=$(service_path)"
EnvironmentFile=-$APP_DIR/.env
ExecStart="$NODE_BIN" "$APP_DIR/server.js"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  as_root install -m 644 "$tmp" "$UNIT"
  rm -f "$tmp"
  as_root systemctl daemon-reload
  as_root systemctl enable "$SERVICE" >/dev/null 2>&1 || warn "設定開機自動啟動失敗（systemctl enable $SERVICE），這次還是會啟動"
  as_root systemctl restart "$SERVICE"
}

start_background() {
  local envs=() k
  for k in "${CONFIG_KEYS[@]}"; do
    if [ -n "${!k:-}" ]; then envs+=("$k=${!k}"); fi
  done
  cd "$APP_DIR"
  nohup env "${envs[@]}" PATH="$NODE_DIR:$PATH" "$NODE_BIN" "$APP_DIR/server.js" >>"$APP_DIR/server.log" 2>&1 &
  echo "$!" >"$APP_DIR/.server.pid"
}

show_logs() {
  if [ "$MODE" = systemd ]; then
    as_root journalctl -u "$SERVICE" -n 30 --no-pager || true
  else
    tail -n 30 "$APP_DIR/server.log" || true
  fi
}

wait_ready() {
  local host="${HOST:-0.0.0.0}" i
  case "$host" in 0.0.0.0 | '::') host=127.0.0.1 ;; esac
  CHECK_URL="http://$host:$PORT"
  for ((i = 0; i < 30; i++)); do
    if "$NODE_BIN" -e 'fetch(process.argv[1] + "/api/status").then((r) => process.exit(r.ok ? 0 : 1), () => process.exit(1))' "$CHECK_URL"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# 讀一次數據：順便確認 ccusage 能跑，第一次也會把結果快取起來
first_read() {
  "$NODE_BIN" -e '
    const zh = (n) => n >= 1e8 ? (n / 1e8).toFixed(2) + " 億" : n >= 1e4 ? (n / 1e4).toFixed(1) + " 萬" : String(n);
    fetch(process.argv[1] + "/api/usage", { signal: AbortSignal.timeout(150000) })
      .then(async (r) => {
        const j = await r.json();
        if (!r.ok) throw new Error(j.error || "HTTP " + r.status);
        const t = j.days[j.days.length - 1];
        const used = j.days.filter((d) => d.totalTokens > 0).length;
        console.log(`    今天（${j.today}，${j.timezone}）到目前為止 ${zh(t.totalTokens)} tokens；最近 ${j.days.length} 天裡有 ${used} 天有紀錄`);
      })
      .catch((e) => { console.error("    " + e.message); process.exit(1); });' "$CHECK_URL"
}

# ---------- 告訴你從哪裡連 ----------

print_urls() {
  local lines name ip pub="" listed=""
  step "${G}完成！${N}打開瀏覽器連到："
  say ""
  case "${HOST:-0.0.0.0}" in
    0.0.0.0 | '::') ;;
    127.0.0.1 | localhost)
      say "    這台電腦   http://localhost:$PORT"
      say "    ${D}（HOST=$HOST，只有這台電腦自己連得到）${N}"
      return
      ;;
    *)
      say "    http://$HOST:$PORT"
      return
      ;;
  esac
  say "    這台電腦   http://localhost:$PORT"
  lines="$("$NODE_BIN" -e '
    const skip = /^(docker|br-|veth|virbr|cni|flannel|podman|lxc|vEthernet)/;
    for (const [name, list] of Object.entries(require("os").networkInterfaces()))
      for (const n of list || [])
        if (n.family === "IPv4" && !n.internal && !skip.test(name)) console.log(name + " " + n.address);')"
  while read -r name ip; do
    [ -n "$ip" ] || continue
    listed="$listed $ip "
    case "$ip" in
      100.*) say "    Tailscale  http://$ip:$PORT    ${D}($name)${N}" ;;
      *) say "    區網       http://$ip:$PORT    ${D}($name)${N}" ;;
    esac
  done <<<"$lines"
  # 對外 IP（雲端主機或家裡的路由器）；跟上面重複就不印
  if have curl; then pub="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"; fi
  if [[ "$pub" =~ ^[0-9.]+$ ]] && [[ "$listed" != *" $pub "* ]]; then
    say "    外網       http://$pub:$PORT    ${D}(要在路由器設 port forwarding，或在雲端主機的防火牆開放 $PORT)${N}"
  fi
  say ""
  say "    Port：${B}$PORT${N}"

  if have ufw && as_root_quiet ufw status 2>/dev/null | grep -q 'Status: active'; then
    say ""
    warn "這台有開 ufw 防火牆，其他電腦要連的話：sudo ufw allow $PORT/tcp"
  elif have systemctl && systemctl is-active --quiet firewalld 2>/dev/null; then
    say ""
    warn "這台有開 firewalld，其他電腦要連的話：sudo firewall-cmd --permanent --add-port=$PORT/tcp && sudo firewall-cmd --reload"
  fi
}

print_manage() {
  say ""
  say "${B}之後要用的指令${N}"
  if [ "$MODE" = systemd ]; then
    say "    看狀態     systemctl status $SERVICE"
    say "    看 log     journalctl -u $SERVICE -f"
    say "    重新啟動   sudo systemctl restart $SERVICE"
  else
    say "    看 log     tail -f $APP_DIR/server.log"
    say "    ${D}這台沒有 systemd（或設了 NO_SYSTEMD=1），重開機後要再執行一次 install.sh${N}"
  fi
  if [ "$FROM_CHECKOUT" = 1 ]; then
    say "    更新       cd $APP_DIR && git pull && ./install.sh"
  else
    say "    更新       再跑一次同一行 curl … | bash"
  fi
  say "    改設定     編輯 $APP_DIR/.env，再跑一次 install.sh"
  say "    移除       $APP_DIR/install.sh uninstall"
}

# ---------- 主程式 ----------

cmd_uninstall() {
  resolve_app_dir
  local done=0
  if [ -f "$UNIT" ]; then
    as_root systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    as_root rm -f "$UNIT"
    as_root systemctl daemon-reload
    say "已停止並移除 systemd 服務 $SERVICE"
    done=1
  fi
  if [ -n "$(bg_pid || true)" ]; then
    stop_existing
    say "已停止背景程式"
    done=1
  fi
  [ "$done" = 1 ] || say "沒有找到正在跑的 $SERVICE"
  say "程式還在 $APP_DIR（不需要的話可以直接刪掉：rm -rf $APP_DIR）；你的 Claude Code／Codex 紀錄沒有動。"
}

cmd_install() {
  if is_root && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    die "請不要用 sudo 執行。直接用你自己的帳號跑 ./install.sh，需要 root 的步驟腳本會自己問密碼（要讀的是你帳號底下的 ~/.claude 和 ~/.codex）。"
  fi
  PORT_ARG="${PORT:-}" # 執行時有給 PORT 就一定用它；沒給的話沿用上次的，被佔用再往後找

  resolve_app_dir
  fetch_app
  say "    程式位置：$APP_DIR"
  load_config

  step "檢查 Node.js"
  ensure_node
  install_deps
  check_data

  if use_systemd; then MODE=systemd; else MODE=background; fi
  step "啟動（$([ "$MODE" = systemd ] && echo "systemd 服務 $SERVICE，開機自動啟動" || echo "背景程式")）"
  precheck_port
  stop_existing # 先停掉舊的，它佔的 port 才會空出來
  choose_port
  write_config
  if [ "$MODE" = systemd ]; then start_systemd; else start_background; fi

  if ! wait_ready; then
    warn "等了 30 秒還連不上 $CHECK_URL，最近的 log："
    show_logs
    exit 1
  fi
  say "    伺服器已啟動，第一次讀取用量數據（大約 10 秒）…"
  if ! first_read; then
    warn "網頁開起來了，但讀不到用量數據（上面是錯誤訊息），最近的 log："
    show_logs
  fi
  print_urls
  print_manage
}

main() {
  case "${1:-install}" in
    install) cmd_install ;;
    uninstall | remove) cmd_uninstall ;;
    -h | --help | help) sed -n '2,13p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//' ;;
    *) die "不認得的指令：$1（可以用 install、uninstall）" ;;
  esac
}

main "$@"
