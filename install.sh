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
# label 可覆蓋純粹是為了能測這支腳本本身：搭配另一個 HOME 與 port，就能把安裝流程完整跑到
# 底（含 launchctl 註冊與健康檢查）而不動到正式服務。這支腳本的失敗方式都是「執行到某一行
# 才炸」，不整段跑過就等於沒驗證。
LABEL="${VC_LABEL:-io.nextdrive.vision-claude-server}"
DATA_DIR="$HOME/.vision-claude"
INSTALL_DIR="$DATA_DIR/server"
CONFIG="$DATA_DIR/config.json"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
OUT_LOG="$HOME/Library/Logs/vision-claude-server.out.log"
ERR_LOG="$HOME/Library/Logs/vision-claude-server.err.log"
NODE="$INSTALL_DIR/VisionClaudeServer"
# /Applications 是全機器共用的路徑,覆寫純粹是為了能測這支腳本本身——理由同 VC_LABEL。
APP_DIR="${VC_APP_DIR:-/Applications}"
APP_PATH="$APP_DIR/VisionClaude.app"
APP_TARBALL_NAME="VisionClaude-macos.tar.gz"
# 指向本機 tarball 時跳過下載直接用它。理由同 VC_LABEL/VC_APP_DIR:要能在 dist repo
# 還沒有 App asset 的情況下,把安裝流程完整跑到底驗證這支腳本本身。
APP_TARBALL_LOCAL="${VC_APP_TARBALL:-}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m ✗\033[0m %s\n' "$1" >&2; exit 1; }
warn() { printf '\033[1;33m ！\033[0m %s\n' "$1" >&2; }

# 「沒有人在聽」不是錯誤，是這個腳本最想看到的結果——但 lsof 對它回 exit 1，在
# `set -e -o pipefail` 下會讓 `HOLDERS="$(port_in_use ... | tr ...)"` 這種賦值整個中止腳本。
# 實測(2026-08-14)就是這樣停在「註冊登入自啟服務」之後：plist 寫好了、服務卻沒註冊。
# 用 `|| true` 把它收成永遠成功、以輸出是否為空表達結果。
port_in_use() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null || true
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

# ── macOS App ────────────────────────────────────────────────────────────────
# 放在 server 之後安裝:App 安裝失敗時 server 仍然可用,而且 App 一啟動就有東西可連。
#
# 這裡所有失敗路徑都用 `warn` + `return 1`，不用 `die`:server 到這一步已經裝好且在跑，
# 整支腳本不該以離開碼 1 收場，使用者更需要看到結尾那段「重啟／看 log／移除」。呼叫端
# 負責把 return 1 轉成一段警告，並照常印出結尾區塊。
install_app() {
  local url="https://github.com/$DIST_REPO/releases/latest/download/$APP_TARBALL_NAME"
  local tmp; tmp="$(mktemp -d)"

  # staging 必須跟 $APP_PATH 在同一個檔案系統(這裡就是 $APP_DIR 底下),不能借用 $tmp:
  # 稍後靠 mv 做原子替換的前提是來源與目的地同一個檔案系統,跨檔案系統的 mv 會退化成
  # 複製再刪除,那就完全失去 staging 的意義。
  local staging="$APP_DIR/.VisionClaude.app.new"
  # staging 一起掛在 trap 上:任何一條失敗路徑都不能在 /Applications 留下一個 6MB 的
  # 隱藏孤兒——它是點號開頭的，Finder 看不到，也沒有任何後續流程會去清它。成功路徑上
  # staging 早已被 mv 走，這個 rm 是 no-op。
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' '$staging'" RETURN

  if [ -n "$APP_TARBALL_LOCAL" ]; then
    info "使用本機 App 包：$APP_TARBALL_LOCAL"
    [ -f "$APP_TARBALL_LOCAL" ] || { warn "找不到 $APP_TARBALL_LOCAL"; return 1; }
    cp "$APP_TARBALL_LOCAL" "$tmp/$APP_TARBALL_NAME" || { warn "複製本機 App 包失敗。"; return 1; }
  else
    info "下載 macOS App"
    curl -fsSL "$url" -o "$tmp/$APP_TARBALL_NAME" || { warn "下載 App 失敗：$url"; return 1; }
  fi
  tar -xzf "$tmp/$APP_TARBALL_NAME" -C "$tmp" || { warn "App 解壓失敗，檔案可能不完整。"; return 1; }
  [ -d "$tmp/VisionClaude.app" ] || { warn "解壓結果裡沒有 VisionClaude.app。"; return 1; }

  # App 是純 client,所有狀態(session、對話)都在 server 端,關掉不會遺失任何東西,
  # 頂多是輸入框裡尚未送出的草稿。
  if pgrep -f "$APP_PATH/Contents/MacOS/VisionClaude" >/dev/null 2>&1; then
    info "關閉執行中的 App"
    osascript -e 'quit app "VisionClaude"' 2>/dev/null || true
    sleep 1
    pkill -f "$APP_PATH/Contents/MacOS/VisionClaude" 2>/dev/null || true
    sleep 1
  fi

  mkdir -p "$APP_DIR" || { warn "建立 $APP_DIR 失敗。"; return 1; }

  # 每一次都從乾淨的 staging 開始:上一次中途失敗留下的半成品若被沿用，可能混進舊檔案。
  rm -rf "$staging" || { warn "清不掉舊的 ${staging}，請手動移除後重跑。"; return 1; }
  ditto "$tmp/VisionClaude.app" "$staging" || { warn "安裝 App 到 $APP_DIR 失敗。"; return 1; }

  # curl + tar 不會產生 quarantine,這裡是防禦性清除(例如使用者改用瀏覽器下載腳本
  # 或壓縮檔的情況)。-r 是必要的:bundle 內層檔案各自帶屬性。
  xattr -cr "$staging" 2>/dev/null || true

  # 驗證要在替換 $APP_PATH 之前做:這裡失敗就直接放棄，舊 App 完全沒被動到，
  # 使用者手上仍是原本能用的版本。
  codesign --verify --deep --strict "$staging" 2>/dev/null \
    || { warn "App 簽章驗證失敗，安裝可能不完整（舊版 App 未受影響）。"; return 1; }

  # 為什麼是「先把舊的改名挪開」而不是「先刪掉舊的」:App Store／TestFlight 裝進
  # /Applications 的 bundle 是 root:wheel 擁有的，admin 使用者 rm 不掉（rm 不會提權），
  # 那條路對每一個從 TestFlight 遷移過來的使用者都會 Permission denied。但 /Applications
  # 本身是 root:admin drwxrwxr-x，admin 對它有寫入權限，而「同一個父目錄之內的改名」只
  # 需要父目錄可寫——所以那是唯一搬得動 root 擁有的 bundle 的方式。
  #
  # backup 一定要留在 $APP_DIR 底下，不能順手丟去垃圾桶或別的目錄:跨父目錄搬一個目錄
  # 會動到它的 `..`，因此另外需要對「被搬的那個目錄本身」有寫入權限，對 root:wheel 的
  # bundle 不成立（2026-08-25 沙盒實測:同層改名成功、搬到別的目錄 Permission denied）。
  #
  # 順帶保留原本的好處:「舊的離開」到「新的就位」之間只留一次 rename 的窗口，而不是
  # 整個 ditto 的時長，把可能「新舊都不在」的空窗壓到最小。
  local backup="$APP_DIR/.VisionClaude.app.old.$$"
  if [ -e "$APP_PATH" ]; then
    mv "$APP_PATH" "$backup" || {
      warn "無法移走舊的 ${APP_PATH}（多半是 App Store／TestFlight 裝的，rm／mv 都不會提權）。
     請在 Finder 裡把它拖到垃圾桶（Finder 會跳出授權對話框）後重跑這一行。"
      return 1
    }
  fi
  mv "$staging" "$APP_PATH" || {
    [ -e "$backup" ] && mv "$backup" "$APP_PATH"
    warn "安裝 App 失敗，已還原舊版。"
    return 1
  }
  # 新版已經就位，收尾的刪除失敗不該讓整個安裝被判定為失敗（舊 bundle 若是 root:wheel
  # 就真的只有 root 刪得掉），所以這裡只警告並給一行可以直接貼的指令。
  rm -rf "$backup" 2>/dev/null \
    || warn "新版已裝好，但舊版留在 ${backup}（root 擁有，只有 root 刪得掉）。要清掉就跑：
     sudo rm -rf '${backup}'"

  ok "已安裝 $APP_PATH"
}

uninstall() {
  info "停止並移除服務"
  stop_service
  rm -f "$PLIST"
  rm -rf "$INSTALL_DIR"
  ok "已移除 $INSTALL_DIR 與 $PLIST"
  # 安裝時一起裝,移除也要一起移除,否則會留下一個連不到 server 的殘骸。
  if [ -d "$APP_PATH" ]; then
    osascript -e 'quit app "VisionClaude"' 2>/dev/null || true
    sleep 1
    pkill -f "$APP_PATH/Contents/MacOS/VisionClaude" 2>/dev/null || true
    # rm 不會提權,App Store／TestFlight 裝的 bundle(root:wheel)刪不掉。失敗不能讓
    # set -e 中止 uninstall——後面那句「設定與 session 記錄保留在…」才是使用者需要的資訊。
    rm -rf "$APP_PATH" 2>/dev/null || true
    if [ -e "$APP_PATH" ]; then
      warn "無法移除 ${APP_PATH}（多半是 App Store／TestFlight 裝的）。請在 Finder 裡把它拖到垃圾桶。"
    else
      ok "已移除 $APP_PATH"
    fi
  fi
  echo "   設定與 session 記錄保留在 ${DATA_DIR}（要一併清掉就手動 rm -rf 它）"
  exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

# ── 環境檢查 ────────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "這個 server 只跑在 macOS（偵測到 $(uname -s)）。"

ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || die "目前只提供 Apple Silicon（arm64）的發佈包，這台是 ${ARCH}。"

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
ok "安裝到 ${INSTALL_DIR}（版本 ${VERSION}）"

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
  die "port ${PORT} 被佔用中（pid: ${HOLDERS}）。
     常見原因是你另外手動跑了一個 server（pnpm dev / nohup）。
     先結束它再重跑這行；服務本身已經停好，重跑不會有副作用。"
fi

# bootout 回來、port 也放掉了，仍不代表馬上能 bootstrap：launchd 那邊的 service 可能還在
# 過渡狀態，這時 bootstrap 會回 "Bootstrap failed: 5: Input/output error"。在 set -e 下那就是
# 靜默中止——使用者只看到輸出停在「註冊登入自啟服務」，服務沒起來，也沒有任何錯誤訊息。
# 實測(2026-08-14)就是這樣：手動再跑一次同一行 bootstrap 立刻就成功。
bootstrap_service() {
  local err=""
  for _ in $(seq 1 8); do
    if err="$(launchctl bootstrap "$DOMAIN" "$PLIST" 2>&1)"; then return 0; fi
    sleep 1
  done
  die "註冊服務失敗：${err}
     可以手動重試：launchctl bootstrap ${DOMAIN} ${PLIST}"
}
bootstrap_service
# 這兩個失敗不致命：enable 只在服務曾被使用者停用時才有作用，而 plist 的 RunAtLoad 已經
# 會把 server 拉起來，kickstart 只是讓它立刻發生。
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true

# ── 確認真的起來了 ──────────────────────────────────────────────────────────
info "等待 server 回應"
for _ in $(seq 1 40); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    ok "server 已啟動（port ${PORT}，版本 ${VERSION}）"
    # App 沒裝成功不影響 server,結尾區塊照印:那裡的「重啟／看 log／移除」與配對網址
    # 對只有 server 的使用者一樣有用,而以 die 收場只會讓人以為整件事都失敗了。
    if install_app; then
      APP_NOTE="  server 與 macOS App 都已就緒。App 已安裝到 ${APP_PATH}。"
    else
      APP_NOTE="  server 已就緒，但 macOS App 沒有裝成功（原因見上面那行警告）。
  server 本身完全正常，Vision Pro 端現在就能配對使用;處理完上面說的問題後重跑
  同一行，就會把 App 補上。"
    fi
    cat <<DONE_EOF

${APP_NOTE}

  配對（Vision Pro 與 macOS App 都要各做一次）：打開下面這一頁，按「在 App 中開啟」，
  server 位址與 token 就會帶進 App。在這台 Mac 的瀏覽器打開會開啟剛裝好的 macOS App；
  Vision Pro 端請在 Vision Pro 的瀏覽器打開同一頁，位址換成這台 Mac 的區網 IP：

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
