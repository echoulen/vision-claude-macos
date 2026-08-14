#!/bin/bash
# vision-claude server 一鍵安裝／更新／解除安裝。
#
#   curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-dist/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# 做完這些事：下載發佈包 → 解壓到 ~/.vision-claude/server → 產生設定 → 註冊成登入自啟的
# 常駐服務 → 等它真的起來 → 印出配對網址。使用者不需要 clone repo，也不需要先裝 node。
#
# 重跑同一行就是更新（會先停掉舊服務再換檔）。設定與 session 資料都在 ~/.vision-claude/
# 底下、跟程式目錄分開，更新不會動到它們。
set -euo pipefail

DIST_REPO="${VC_DIST_REPO:-echoulen/vision-claude-dist}"
LABEL="io.nextdrive.vision-claude-server"
DATA_DIR="$HOME/.vision-claude"
INSTALL_DIR="$DATA_DIR/server"
CONFIG="$DATA_DIR/config.json"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
OUT_LOG="$HOME/Library/Logs/vision-claude-server.out.log"
ERR_LOG="$HOME/Library/Logs/vision-claude-server.err.log"
NODE="$INSTALL_DIR/VisionClaudeServer"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m ✗\033[0m %s\n' "$1" >&2; exit 1; }

port_in_use() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null
}

# `launchctl bootout` 回來時 process 不保證已經退出：server 收到 SIGTERM 會先去收掉每個
# session 的常駐 claude process group（它們是 detached 的，不收會變孤兒），那需要時間。
# 沒等它把 port 放掉就往下走，後面的 port 檢查會把「還在收尾的自己」誤判成「被別的服務
# 佔用」而中止安裝——正在跑 session 的機器最容易踩到。
stop_service() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  local port="${1:-}"
  [ -n "$port" ] || return 0
  for _ in $(seq 1 30); do
    [ -z "$(port_in_use "$port")" ] && return 0
    sleep 0.5
  done
  return 0   # 等不到就交給後面的 port 檢查去報告，那裡的訊息更具體
}

# 既有設定的 port（要在停服務前就知道，才等得到正確的 port 被放掉）。$1 = node 執行檔。
read_configured_port() {
  "$1" -e '
    const fs = require("fs");
    try { console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).port ?? 8790); }
    catch { console.log(8790); }
  ' "$CONFIG"
}

uninstall() {
  info "停止並移除服務"
  stop_service
  rm -f "$PLIST"
  rm -rf "$INSTALL_DIR"
  ok "已移除 $INSTALL_DIR 與 $PLIST"
  echo "   設定與 session 記錄保留在 $DATA_DIR（要一併清掉就手動 rm -rf 它）"
  exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

# ── 環境檢查 ────────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "這個 server 只跑在 macOS（偵測到 $(uname -s)）。"

ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || die "目前只提供 Apple Silicon（arm64）的發佈包，這台是 $ARCH。"

# 這個腳本是在使用者自己的終端機裡跑的，PATH 就是他平常的 PATH——claude 找得到、
# 等一下寫進 LaunchAgent 的快照也才是對的（launchd 自己完全不繼承登入 shell 的 PATH）。
CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || die "找不到 claude CLI。先安裝 Claude Code 再重跑這行：
     curl -fsSL https://claude.ai/install.sh | bash"
ok "claude CLI：$CLAUDE_BIN"

# ── 下載並替換程式目錄 ──────────────────────────────────────────────────────
TARBALL_NAME="vision-claude-server-macos-$ARCH.tar.gz"
URL="https://github.com/$DIST_REPO/releases/latest/download/$TARBALL_NAME"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "下載 $TARBALL_NAME"
curl -fSL --progress-bar "$URL" -o "$TMP/$TARBALL_NAME" \
  || die "下載失敗：$URL"
tar -xzf "$TMP/$TARBALL_NAME" -C "$TMP" || die "解壓失敗，檔案可能不完整。"
[ -x "$TMP/vision-claude-server/VisionClaudeServer" ] || die "發佈包內容不符預期。"

# 先停服務再換檔：直接覆寫執行中的 binary 會讓還在跑的 process 當場崩潰。
# port 要在停服務「之前」就從既有設定讀出來——停完才知道要等哪個 port 被放掉就太遲了。
# 這時 $INSTALL_DIR 還沒換上新版，用剛解壓出來的那個 node。
PORT="$(read_configured_port "$TMP/vision-claude-server/VisionClaudeServer")"
info "停止舊服務（若有），等 port $PORT 釋放"
stop_service "$PORT"

mkdir -p "$DATA_DIR"
rm -rf "$INSTALL_DIR"
mv "$TMP/vision-claude-server" "$INSTALL_DIR"
VERSION="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo unknown)"
ok "安裝到 $INSTALL_DIR（版本 $VERSION）"

# ── 設定 ────────────────────────────────────────────────────────────────────
# token 不在這裡產生：server 首次啟動會自己補一把隨機值（見 server/src/config.ts），
# 使用者從頭到尾不必看到那個字串，配對頁面會把它帶給 App。
#
# 這裡只寫兩樣安裝當下才知道的事：claude 的絕對路徑，以及「新安裝要讓 Vision Pro 連得進來」
# 的 bind。已經有設定檔時只更新 claudeBin，bind 與 port 維持使用者原本的選擇。
#
# 用剛解壓的 node 改 JSON，不假設這台機器有 node/python/jq。
if [ -f "$CONFIG" ]; then
  info "更新既有設定的 claudeBin"
  "$NODE" -e '
    const fs = require("fs");
    const [file, claudeBin] = process.argv.slice(1);
    const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
    cfg.claudeBin = claudeBin;
    fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
  ' "$CONFIG" "$CLAUDE_BIN"
else
  info "建立設定 $CONFIG"
  "$NODE" -e '
    const fs = require("fs");
    const [file, claudeBin] = process.argv.slice(1);
    fs.writeFileSync(file, JSON.stringify({
      bind: ["127.0.0.1", "lan"],
      claudeBin,
    }, null, 2) + "\n");
  ' "$CONFIG" "$CLAUDE_BIN"
fi
# 設定可能剛被建立（新安裝）或被改過，重讀一次確保接下來註冊與健康檢查用的是同一個 port。
PORT="$(read_configured_port "$NODE")"

# ── LaunchAgent ─────────────────────────────────────────────────────────────
# PATH 快照是必要的：claude 底下還會 spawn 各種 MCP server（uvx、npx…），launchd 給的
# 預設 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，那些工具一個都找不到。
info "註冊登入自啟服務"
mkdir -p "$HOME/Library/LaunchAgents"

# plist 是 XML：路徑或 PATH 裡只要有一個 & 就會讓整份設定檔解析失敗，服務靜默載入不起來。
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
X_INSTALL_DIR="$(xml_escape "$INSTALL_DIR")"
X_PATH="$(xml_escape "$PATH")"
X_HOME="$(xml_escape "$HOME")"
X_OUT_LOG="$(xml_escape "$OUT_LOG")"
X_ERR_LOG="$(xml_escape "$ERR_LOG")"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$X_INSTALL_DIR/VisionClaudeServer</string>
    <string>$X_INSTALL_DIR/lib/server.js</string>
  </array>
  <key>WorkingDirectory</key><string>$X_INSTALL_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$X_PATH</string>
    <key>HOME</key><string>$X_HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$X_OUT_LOG</string>
  <key>StandardErrorPath</key><string>$X_ERR_LOG</string>
</dict>
</plist>
PLIST_EOF

# 走到這裡舊服務早就停了，port 還被佔住就真的是別人的東西（手動跑的 pnpm dev、或別的程式）。
HOLDERS="$(port_in_use "$PORT" | tr '\n' ' ')"
if [ -n "$HOLDERS" ]; then
  die "port $PORT 被佔用中（pid: $HOLDERS）。
     常見原因是你另外手動跑了一個 server（pnpm dev / nohup）。
     先結束它再重跑這行；服務本身已經停好，重跑不會有副作用。"
fi

launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"

# ── 確認真的起來了 ──────────────────────────────────────────────────────────
info "等待 server 回應"
for _ in $(seq 1 40); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    ok "server 已啟動（port $PORT，版本 $VERSION）"
    cat <<DONE_EOF

  接下來在這台 Mac 的瀏覽器打開配對頁面，按「在 App 中開啟」即可連上 Vision Pro／
  macOS App，全程免打字：

      http://127.0.0.1:$PORT/pair

  其他指令：
      重啟    launchctl kickstart -k $DOMAIN/$LABEL
      看 log  tail -f $ERR_LOG
      移除    curl -fsSL https://raw.githubusercontent.com/$DIST_REPO/main/install.sh | bash -s -- --uninstall
DONE_EOF
    exit 0
  fi
  sleep 0.5
done

die "server 在 20 秒內沒有回應，看一下錯誤輸出：
     tail -n 50 $ERR_LOG"
