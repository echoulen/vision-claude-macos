#!/bin/bash
# vision-claude server 一鍵安裝／更新／解除安裝。
#
#   curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --server      只裝 server 與選單列小程式
#   curl -fsSL .../install.sh | bash -s -- --app         只裝 macOS App
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# 沒有參數＝ --server 與 --app 兩者都裝（維持與舊指令相同的行為）。
#
# 做完這些事：下載發佈包 → 解壓到 ~/.vision-claude/server → 產生設定 → 註冊成登入自啟的
# 常駐服務 → 等它真的起來 → 印出配對網址。使用者不需要 clone repo，也不需要先裝 node。
#
# 重跑同一行就是更新（會先停掉舊服務再換檔）。設定與 session 資料都在 ~/.vision-claude/
# 底下、跟程式目錄分開，更新不會動到它們。
set -euo pipefail

DIST_REPO="${VC_DIST_REPO:-echoulen/vision-claude-macos}"
# label 可覆蓋純粹是為了能測這支腳本本身：搭配另一個 HOME 與 port，就能把安裝流程完整跑到
# 底（含 launchctl 註冊與健康檢查）而不動到正式服務。這支腳本的失敗方式都是「執行到某一行
# 才炸」，不整段跑過就等於沒驗證。
DEFAULT_LABEL="io.echoulen.vision-claude-server"
LABEL="${VC_LABEL:-$DEFAULT_LABEL}"
# 改名(io.nextdrive → io.echoulen)前註冊的服務。它指向同一個安裝目錄、綁同一個 port,
# 留著會在下次登入被 launchd 拉起來跟新服務搶 8790——而那時 port 檢查只會說「被別的服務
# 佔用」然後中止安裝,使用者完全看不出真正的原因。用 VC_LABEL 覆寫時一律不碰它:測試用的
# 假 label 不該連帶拆掉正式服務。
LEGACY_LABEL="io.nextdrive.vision-claude-server"
[ "$LABEL" = "$DEFAULT_LABEL" ] || LEGACY_LABEL=""
DATA_DIR="$HOME/.vision-claude"
INSTALL_DIR="$DATA_DIR/server"
CONFIG="$DATA_DIR/config.json"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_PLIST="${LEGACY_LABEL:+$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist}"
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
# 選單列小程式（VisionClaude Server.app）：跟著 server 一起裝，由自己的 LaunchAgent 在登入時
# 帶起來（只負責開 App，不是常駐服務，所以 KeepAlive 為 false）。label 可覆蓋的理由同 VC_LABEL。
MENUBAR_LABEL="${VC_MENUBAR_LABEL:-io.echoulen.vision-claude-menubar}"
MENUBAR_PLIST="$HOME/Library/LaunchAgents/$MENUBAR_LABEL.plist"
MENUBAR_APP_NAME="VisionClaude Server.app"
MENUBAR_APP_PATH="$APP_DIR/$MENUBAR_APP_NAME"
# 使用者用 --uninstall 移除過小程式的標記。server 啟動時會補裝缺少的小程式（見
# server/src/update/menubarInstaller.ts），看到這個標記就不裝回來；重新跑 --server（或無參數）
# 等於使用者又要它了，安裝時刪掉。放在資料目錄而不是程式目錄：uninstall 會刪掉後者。
MENUBAR_DISABLED_MARKER="$DATA_DIR/menubar-disabled"

# 安裝模式（--server／--app／兩者）。解析在下面的參數處理。
MODE="all"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m ✗\033[0m %s\n' "$1" >&2; exit 1; }
warn() { printf '\033[1;33m ！\033[0m %s\n' "$1" >&2; }

# plist 是 XML：路徑或 PATH 裡只要有一個 & 就會讓整份設定檔解析失敗，服務靜默載入不起來。
# 定義放在這裡而不是寫 plist 的地方：server 與選單列小程式兩段都要用，而選單列那段比較早跑。
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

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
  # 舊 label 的服務與 plist 一起收掉,否則它會在下次登入自己回來。
  if [ -n "$LEGACY_LABEL" ]; then
    launchctl bootout "$DOMAIN/$LEGACY_LABEL" 2>/dev/null || true
    rm -f "$LEGACY_PLIST"
  fi
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
    info "Using local App bundle: $APP_TARBALL_LOCAL"
    [ -f "$APP_TARBALL_LOCAL" ] || { warn "$APP_TARBALL_LOCAL not found"; return 1; }
    cp "$APP_TARBALL_LOCAL" "$tmp/$APP_TARBALL_NAME" || { warn "Failed to copy local App bundle."; return 1; }
  else
    info "Downloading macOS App"
    curl -fsSL "$url" -o "$tmp/$APP_TARBALL_NAME" || { warn "Failed to download App: $url"; return 1; }
  fi
  tar -xzf "$tmp/$APP_TARBALL_NAME" -C "$tmp" || { warn "Failed to extract App archive, the file may be incomplete."; return 1; }
  [ -d "$tmp/VisionClaude.app" ] || { warn "VisionClaude.app not found in the extracted archive."; return 1; }

  # App 是純 client,所有狀態(session、對話)都在 server 端,關掉不會遺失任何東西,
  # 頂多是輸入框裡尚未送出的草稿。
  #
  # 有沒有在跑要記下來:換完檔案要把它開回來(使用者按的是「更新」,不是「關掉 App」),
  # 但只限原本就開著的情況——沒開著的時候硬開一個視窗出來是多管閒事。
  local app_was_running=0
  if pgrep -f "$APP_PATH/Contents/MacOS/VisionClaude" >/dev/null 2>&1; then
    app_was_running=1
    info "Quitting running App"
    osascript -e 'quit app "VisionClaude"' 2>/dev/null || true
    sleep 1
    pkill -f "$APP_PATH/Contents/MacOS/VisionClaude" 2>/dev/null || true
    sleep 1
  fi

  mkdir -p "$APP_DIR" || { warn "Failed to create $APP_DIR."; return 1; }

  # 每一次都從乾淨的 staging 開始:上一次中途失敗留下的半成品若被沿用，可能混進舊檔案。
  rm -rf "$staging" || { warn "Could not remove stale ${staging}, remove it manually and rerun."; return 1; }
  ditto "$tmp/VisionClaude.app" "$staging" || { warn "Failed to install App to $APP_DIR."; return 1; }

  # curl + tar 不會產生 quarantine,這裡是防禦性清除(例如使用者改用瀏覽器下載腳本
  # 或壓縮檔的情況)。-r 是必要的:bundle 內層檔案各自帶屬性。
  xattr -cr "$staging" 2>/dev/null || true

  # 驗證要在替換 $APP_PATH 之前做:這裡失敗就直接放棄，舊 App 完全沒被動到，
  # 使用者手上仍是原本能用的版本。
  codesign --verify --deep --strict "$staging" 2>/dev/null \
    || { warn "App signature verification failed, the install may be incomplete (the previous App is unaffected)."; return 1; }

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
      warn "Could not move the existing ${APP_PATH} out of the way (it's likely installed via App Store/TestFlight, and rm/mv can't elevate privileges).
     Drag it to the Trash in Finder (Finder will prompt for authorization), then rerun this line."
      return 1
    }
  fi
  mv "$staging" "$APP_PATH" || {
    [ -e "$backup" ] && mv "$backup" "$APP_PATH"
    warn "Failed to install App, the previous version has been restored."
    return 1
  }
  # 新版已經就位，收尾的刪除失敗不該讓整個安裝被判定為失敗（舊 bundle 若是 root:wheel
  # 就真的只有 root 刪得掉），所以這裡只警告並給一行可以直接貼的指令。
  rm -rf "$backup" 2>/dev/null \
    || warn "The new App is installed, but the previous version is left at ${backup} (owned by root, only root can delete it). To clean it up, run:
     sudo rm -rf '${backup}'"

  # 開回來只在原本就開著時做,理由見上面 app_was_running。開不起來不該讓整個安裝算失敗——
  # 檔案已經就位了,使用者自己點一下也是一樣的。
  if [ "$app_was_running" = "1" ]; then
    open -a "$APP_PATH" 2>/dev/null || warn "The App is installed but couldn't be reopened; open it from /Applications."
  fi

  ok "Installed $APP_PATH"
}

# ── 選單列小程式 ─────────────────────────────────────────────────────────────
# 發佈包裡的 menubar/VisionClaude Server.app 裝到 /Applications,並註冊一個登入自啟的
# LaunchAgent(只是 `open -a`,不是常駐服務)。在 server 起來之後才做:小程式一啟動就會打
# /health,先有 server 它第一眼看到的就是正確狀態。
#
# 失敗一律 warn + return 1(不是 die),理由同 install_app:server 這時已經在跑,結尾那段
# 配對網址與指令對使用者仍然有用。
install_menubar() {
  # 放在最前面：就算這一版沒有小程式可裝，使用者既然重跑了 server 安裝，之後的版本也該補上。
  rm -f "$MENUBAR_DISABLED_MARKER"
  local src="$INSTALL_DIR/menubar/$MENUBAR_APP_NAME"
  # 舊版發佈包沒有這個目錄。這不是錯誤,只是那一版沒有小程式可裝。
  [ -d "$src" ] || { warn "This release doesn't include the menu bar app; skipping it."; return 1; }

  # 先把 LaunchAgent 收掉再結束行程,否則 launchd 會在我們換檔案的中途把它帶回來。
  launchctl bootout "$DOMAIN/$MENUBAR_LABEL" 2>/dev/null || true
  pkill -f "$MENUBAR_APP_NAME/Contents/MacOS" 2>/dev/null || true
  sleep 1

  # staging 與目的地同一個檔案系統(理由同 install_app 的那段),而且驗證要在替換之前做:
  # 這裡失敗就完全不動已安裝的那份,使用者手上仍是能用的舊版。
  local staging="$APP_DIR/.VisionClaudeServer.app.new"
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'" RETURN

  mkdir -p "$APP_DIR" || { warn "Failed to create $APP_DIR."; return 1; }
  rm -rf "$staging" || { warn "Could not remove stale ${staging}, remove it manually and rerun."; return 1; }
  # ditto 而不是 cp -R:保住 bundle 的簽章與擴充屬性。
  ditto "$src" "$staging" || { warn "Failed to install the menu bar app to $APP_DIR."; return 1; }
  xattr -cr "$staging" 2>/dev/null || true
  codesign --verify --deep --strict "$staging" 2>/dev/null \
    || { warn "Menu bar app signature verification failed, skipping it (the previous version is unaffected)."; return 1; }

  rm -rf "$MENUBAR_APP_PATH" || { warn "Could not replace ${MENUBAR_APP_PATH}; remove it in Finder and rerun."; return 1; }
  mv "$staging" "$MENUBAR_APP_PATH" || { warn "Failed to install ${MENUBAR_APP_PATH}."; return 1; }

  local x_menubar_app; x_menubar_app="$(xml_escape "$MENUBAR_APP_PATH")"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$MENUBAR_PLIST" <<MENUBAR_PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$MENUBAR_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>$x_menubar_app</string>
  </array>
  <key>RunAtLoad</key><true/>
  <!-- open 開完 App 就結束,不是常駐行程:KeepAlive 會讓 launchd 不停地重跑它。 -->
  <key>KeepAlive</key><false/>
</dict>
</plist>
MENUBAR_PLIST_EOF

  # 這三個失敗都不致命:小程式本身已經裝好了,使用者從 /Applications 點一下也能開。
  launchctl bootstrap "$DOMAIN" "$MENUBAR_PLIST" 2>/dev/null || true
  launchctl enable "$DOMAIN/$MENUBAR_LABEL" 2>/dev/null || true
  launchctl kickstart -k "$DOMAIN/$MENUBAR_LABEL" 2>/dev/null || true

  ok "Installed $MENUBAR_APP_PATH (menu bar app, starts at login)"
}

# 解除安裝時一起收掉:LaunchAgent 留著會在下次登入開一個連不到 server 的小程式。
# 同時留下停用標記:使用者之後若只從 App 裝回 server,server 不會自作主張把小程式裝回來。
remove_menubar() {
  mkdir -p "$DATA_DIR" && : > "$MENUBAR_DISABLED_MARKER" || true
  launchctl bootout "$DOMAIN/$MENUBAR_LABEL" 2>/dev/null || true
  rm -f "$MENUBAR_PLIST"
  pkill -f "$MENUBAR_APP_NAME/Contents/MacOS" 2>/dev/null || true
  if [ -d "$MENUBAR_APP_PATH" ]; then
    rm -rf "$MENUBAR_APP_PATH" 2>/dev/null || true
    if [ -e "$MENUBAR_APP_PATH" ]; then
      warn "Could not remove ${MENUBAR_APP_PATH}. Drag it to the Trash in Finder."
    else
      ok "Removed $MENUBAR_APP_PATH"
    fi
  fi
}

uninstall() {
  info "Stopping and removing the service"
  stop_service
  rm -f "$PLIST"
  rm -rf "$INSTALL_DIR"
  ok "Removed $INSTALL_DIR and $PLIST"
  remove_menubar
  # 安裝時一起裝,移除也要一起移除,否則會留下一個連不到 server 的殘骸。
  if [ -d "$APP_PATH" ]; then
    osascript -e 'quit app "VisionClaude"' 2>/dev/null || true
    sleep 1
    pkill -f "$APP_PATH/Contents/MacOS/VisionClaude" 2>/dev/null || true
    # rm 不會提權,App Store／TestFlight 裝的 bundle(root:wheel)刪不掉。失敗不能讓
    # set -e 中止 uninstall——後面那句「設定與 session 記錄保留在…」才是使用者需要的資訊。
    rm -rf "$APP_PATH" 2>/dev/null || true
    if [ -e "$APP_PATH" ]; then
      warn "Could not remove ${APP_PATH} (it's likely installed via App Store/TestFlight). Drag it to the Trash in Finder."
    else
      ok "Removed $APP_PATH"
    fi
  fi
  echo "   Config and session data remain in ${DATA_DIR} (remove them manually with rm -rf if you want them gone too)"
  exit 0
}

case "${1:-}" in
  --uninstall) uninstall ;;
  --server) MODE="server" ;;
  --app) MODE="app" ;;
  "") MODE="all" ;;
  *) die "Unknown option: $1
     Usage: install.sh [--server | --app | --uninstall]   (no option installs both)" ;;
esac

# ── 環境檢查 ────────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "This server only runs on macOS (detected $(uname -s))."

ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || die "Only Apple Silicon (arm64) releases are available right now, this machine is ${ARCH}."

# ── 只裝 App ────────────────────────────────────────────────────────────────
# App 是純 client:它不跑 session,也不需要這台機器上有 claude CLI 或 server,所以這條路
# 在環境檢查之後就直接分出去。這裡失敗就是整件事失敗(沒有別的東西裝成功),用 die 收場。
if [ "$MODE" = "app" ]; then
  install_app || die "The macOS App didn't install (see the warning above)."
  cat <<APP_ONLY_EOF

  The macOS App is installed at ${APP_PATH}.

  Next: pair it with a server. Open that server's pairing page in this Mac's browser and
  tap "Open in App" — the address and token are handed over automatically:

      http://<server address>:8790/pair

  Don't have a server yet? Install one:
      on this Mac      curl -fsSL https://raw.githubusercontent.com/$DIST_REPO/main/install.sh | bash -s -- --server
      on a Windows PC  irm https://raw.githubusercontent.com/$DIST_REPO/main/install.ps1 | iex

APP_ONLY_EOF
  exit 0
fi

# 這個腳本是在使用者自己的終端機裡跑的，PATH 就是他平常的 PATH——claude 找得到、
# 等一下寫進 LaunchAgent 的快照也才是對的（launchd 自己完全不繼承登入 shell 的 PATH）。
CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || die "claude CLI not found. Install Claude Code first, then rerun this line:
     curl -fsSL https://claude.ai/install.sh | bash"
ok "claude CLI: $CLAUDE_BIN"

# ── 下載並替換程式目錄 ──────────────────────────────────────────────────────
TARBALL_NAME="vision-claude-server-macos-$ARCH.tar.gz"
URL="https://github.com/$DIST_REPO/releases/latest/download/$TARBALL_NAME"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "Downloading $TARBALL_NAME"
curl -fSL --progress-bar "$URL" -o "$TMP/$TARBALL_NAME" \
  || die "Download failed: $URL"
tar -xzf "$TMP/$TARBALL_NAME" -C "$TMP" || die "Failed to extract archive, the file may be incomplete."
[ -x "$TMP/vision-claude-server/VisionClaudeServer" ] || die "Release archive contents don't match what was expected."

# 先停服務再換檔：直接覆寫執行中的 binary 會讓還在跑的 process 當場崩潰。
# port 要在停服務「之前」就從既有設定讀出來——停完才知道要等哪個 port 被放掉就太遲了。
# 這時 $INSTALL_DIR 還沒換上新版，用剛解壓出來的那個 node。
PORT="$(read_configured_port "$TMP/vision-claude-server/VisionClaudeServer")"
info "Stopping the previous service (if any), waiting for port $PORT to be released"
stop_service "$PORT"

mkdir -p "$DATA_DIR"
rm -rf "$INSTALL_DIR"
mv "$TMP/vision-claude-server" "$INSTALL_DIR"
VERSION="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo unknown)"
ok "Installed to ${INSTALL_DIR} (version ${VERSION})"

# ── 設定 ────────────────────────────────────────────────────────────────────
# token 不在這裡產生：server 首次啟動會自己補一把隨機值（見 server/src/config.ts），
# 使用者從頭到尾不必看到那個字串，配對頁面會把它帶給 App。
#
# 這裡只寫兩樣安裝當下才知道的事：claude 的絕對路徑，以及「新安裝要讓 Vision Pro 連得進來」
# 的 bind。已經有設定檔時只更新 claudeBin，bind 與 port 維持使用者原本的選擇。
#
# `models` 是例外，升級時一律刪掉：model id 會隨 CLI 改版汰換（claude-fable-5 →
# claude-fable-5-1），留在設定檔裡的舊清單會把選單凍在寫入的那一刻，選到已消失的 id 只會失敗。
# 清單的唯一真相是 server/src/config.ts 的 DEFAULT_MODELS，設定檔沒這個欄位就會 fallback
# 回去（見 config.ts 的 `raw.models ?? DEFAULT_MODELS`）；這裡刪掉而不是寫入新清單，是為了
# 不讓 install.sh 變成第二份要同步維護的清單。
#
# 用剛解壓的 node 改 JSON，不假設這台機器有 node/python/jq。
if [ -f "$CONFIG" ]; then
  info "Updating claudeBin in the existing config"
  "$NODE" -e '
    const fs = require("fs");
    const [file, claudeBin] = process.argv.slice(1);
    const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
    cfg.claudeBin = claudeBin;
    delete cfg.models;
    fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
  ' "$CONFIG" "$CLAUDE_BIN"
else
  info "Creating config $CONFIG"
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
info "Registering the launch-at-login service"
mkdir -p "$HOME/Library/LaunchAgents"

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
  die "Port ${PORT} is already in use (pid: ${HOLDERS}).
     This usually means another server is running manually (pnpm dev / nohup).
     Stop it and rerun this line; the service itself is already stopped, so rerunning is safe."
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
  die "Failed to register the service: ${err}
     You can retry manually: launchctl bootstrap ${DOMAIN} ${PLIST}"
}
bootstrap_service
# 這兩個失敗不致命：enable 只在服務曾被使用者停用時才有作用，而 plist 的 RunAtLoad 已經
# 會把 server 拉起來，kickstart 只是讓它立刻發生。
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true

# ── 確認真的起來了 ──────────────────────────────────────────────────────────
info "Waiting for the server to respond"
for _ in $(seq 1 40); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    ok "Server started (port ${PORT}, version ${VERSION})"
    # 小程式與 App 都是「沒裝成功也不影響 server」,結尾區塊照印:那裡的「重啟／看 log／移除」
    # 與配對網址對只有 server 的使用者一樣有用,而以 die 收場只會讓人以為整件事都失敗了。
    if install_menubar; then
      MENUBAR_NOTE="  The menu bar app is running — the Vision Claude icon in the menu bar shows the
  server status and can start/stop it, copy the pairing link and install updates."
    else
      MENUBAR_NOTE="  The menu bar app was not installed (see the warning above); the server itself is
  fully functional without it."
    fi
    if [ "$MODE" = "all" ]; then
      if install_app; then
        APP_NOTE="  The macOS App is installed at ${APP_PATH}."
      else
        APP_NOTE="  The macOS App failed to install (see the warning above). After fixing the issue
  above, install it on its own with:
      curl -fsSL https://raw.githubusercontent.com/$DIST_REPO/main/install.sh | bash -s -- --app"
      fi
    else
      APP_NOTE="  The macOS App was not installed (--server). To install it on this Mac:
      curl -fsSL https://raw.githubusercontent.com/$DIST_REPO/main/install.sh | bash -s -- --app"
    fi
    cat <<DONE_EOF

  The server is ready (port ${PORT}, version ${VERSION}).

${MENUBAR_NOTE}

${APP_NOTE}

  Pairing (do this once each for Vision Pro and the macOS App): open the page below and
  tap "Open in App" — the server address and token will be passed into the App. Opening
  it in this Mac's browser launches the macOS App; on Vision Pro, open the same page in
  its browser, with the address replaced by this Mac's LAN IP:

      http://127.0.0.1:$PORT/pair

  Install / update commands (each role has its own line):
      Mac server + menu bar app   curl -fsSL https://raw.githubusercontent.com/$DIST_REPO/main/install.sh | bash -s -- --server
      Mac / Vision Pro App        curl -fsSL https://raw.githubusercontent.com/$DIST_REPO/main/install.sh | bash -s -- --app
      Windows server              irm https://raw.githubusercontent.com/$DIST_REPO/main/install.ps1 | iex

  Other commands:
      restart     launchctl kickstart -k $DOMAIN/$LABEL
      view logs   tail -f $ERR_LOG
      uninstall   curl -fsSL https://raw.githubusercontent.com/$DIST_REPO/main/install.sh | bash -s -- --uninstall
DONE_EOF
    exit 0
  fi
  sleep 0.5
done

die "The server didn't respond within 20 seconds, check the error output:
     tail -n 50 $ERR_LOG"
