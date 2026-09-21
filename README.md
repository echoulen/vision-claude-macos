# vision-claude

Run Claude Code on your Mac or Windows PC, drive it from Vision Pro or from a native Mac app.

This repo is the public distribution channel — it hosts the installer and release builds only. The source lives in a private repo.

**[UI design showcase →](https://echoulen.github.io/vision-claude-macos/)**

## Requirements

- **Mac** — Apple Silicon, with the Claude Code CLI already installed and logged in (needed on whichever Mac runs the server; the app alone doesn't need it)
- **Windows PC** (optional, to run sessions there) — Windows 10 version 1803 or later / Windows 11, 64-bit. Git for Windows and Claude Code are installed for you if missing.

## Install

There are three pieces, and each one has its own command. Pick the ones for what that
machine should do — a Mac can be both a server and an app.

| Role | Command |
|---|---|
| Mac server + menu bar app | `curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh \| bash -s -- --server` |
| Mac / Vision Pro app | `curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh \| bash -s -- --app` |
| Windows server | `irm https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1 \| iex` |

Running `install.sh` with no options installs the server, the menu bar app and the Mac app
on that Mac — that's the old one-line command, and it still works.

Nothing to clone, no Node or Xcode required. Re-run the same line to update.

### Mac server + menu bar app

```bash
curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh | bash -s -- --server
```

| | |
|---|---|
| **Server** | `~/.vision-claude/server` — runs as a launchd service, starts at login |
| **Menu bar app** | `/Applications/VisionClaude Server.app` — starts at login, no Dock icon |

The **Vision Claude icon in the menu bar** shows whether the server is running (green),
starting (amber), stopped (gray) or blocked by something else on port 8790 (red).
Click it for a panel that starts and stops the server, copies the pairing link, shows and
renews the pairing token, opens the logs and installs updates; right-click it for the same
actions as a menu. Quitting the menu bar app leaves the server running.

Updates: the menu bar app checks on launch and every six hours, and installs them on
request — it replaces the server and itself, then comes back. There's nothing to do in a
terminal. The Mac app can also trigger the same update remotely (Settings → Servers).

Your settings, tokens and session history live in `~/.vision-claude/` and are never touched
by an update.

To uninstall (removes the server, the menu bar app and the Mac app, keeping
`~/.vision-claude/`):

```bash
curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh | bash -s -- --uninstall
```

### Mac / Vision Pro app

The app is the client: it drives sessions running on any server you pair it with, on this
Mac or on another machine.

```bash
curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh | bash -s -- --app
```

Installs `/Applications/VisionClaude.app`. It needs neither a server nor the Claude Code
CLI on this machine — only a server to pair with.

On **Vision Pro** the app comes from TestFlight; pair it with a server the same way (see
below).

Updates: when the app is paired with a server on the same Mac, Settings → Servers updates
both the app and that server in one step. Otherwise re-run the line above.

### Windows server

Run a server on a Windows PC to work on projects that live there (for example Unreal Engine projects), and drive it from the Mac app over your local network.

In a **normal** (not administrator) PowerShell window:

```powershell
irm https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1 | iex
```

Or from cmd:

```bat
curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1 -o "%TEMP%\vc-install.ps1" && powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\vc-install.ps1"
```

What it does:

| | |
|---|---|
| **Prerequisites** | Installs Git for Windows (via winget) and the native Claude Code if they're missing — it asks first |
| **Server** | `%USERPROFILE%\.vision-claude\server` — started by the VisionClaude tray app whenever this Windows account signs in |
| **Tray app** | `%USERPROFILE%\.vision-claude\tray` — starts at sign-in |
| **Firewall** | Opens TCP 8790 for private networks. This is the only step that asks for administrator approval (one UAC prompt) |

The **VisionClaude icon in the system tray** shows whether the server is running (green), starting (amber) or stopped (gray). Right-click it to start or stop the server, copy the pairing link / pair page URL / server URL / token, or open the logs; double-click it for a small status window, which also lets you renew the token (all paired devices will need to pair again) and install updates. It's also in the Start menu as **VisionClaude** — open it any time to bring up the status window, even while the tray app is already running. Quitting the tray app leaves the server running.

- Everything is installed for the Windows account that runs the command. If several accounts should serve the Mac, run it once in each; only one of them can be signed in and serving at a time.
- Your network must be set to **Private** (Settings → Network & internet), otherwise the Mac can't reach the PC.
- If Claude Code was just installed, sign in once by running `claude` in a new terminal, or from the Claude account section of the Mac app's settings after pairing.

Updates: the status window installs them, and the Mac app can trigger the same update
remotely (Settings → Servers) — the tray app replaces itself afterwards either way.
Re-running the install line works too. Config and session history in
`%USERPROFILE%\.vision-claude\` are kept.

To uninstall (in a normal PowerShell window):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1))) -Uninstall
```

## Getting started

### 1. Pair your devices

When the install finishes it prints a pairing URL:

```
http://127.0.0.1:8790/pair
```

Open it and click **Open in App**. The server address and token are handed over automatically — nothing to type or copy.

- **Mac** — open the URL in a browser on this Mac. It launches the app you just installed. You can also click the menu bar icon → **COPY PAIRING LINK** and paste it into a browser.
- **Vision Pro** — open the same page in the Vision Pro browser, replacing `127.0.0.1` with this Mac's LAN IP. Both devices must be on the same network.
- **Windows server** — the Windows installer prints `http://<PC's LAN IP>:8790/pair`. Open it in a browser on the Mac, click **Yes** on the dialog that appears on the PC, then **Open in App**, or right-click the tray icon → **Copy pairing link** and paste it into a browser on the Mac.

Each machine running the server is paired separately by opening `http://<that machine's IP>:8790/pair` in a browser (or adding it manually in Settings → Servers). The app can stay connected to multiple servers at once — for example a Mac and a Windows PC — each showing up as its own group in the sidebar.

Each device pairs once.

### 2. Start a session

Press **⌘N**, pick a project folder, and start typing. A session is one Claude Code conversation bound to that folder.

Every session gets its own window, and they keep running in the background — start something long, switch away, come back when it's done.

### 3. Handy shortcuts

| | |
|---|---|
| `⌘N` | New session |
| `⌘0` | Session list |
| `⌘1`–`⌘9` | Jump to a session |
| `⌘⇧G` | Tile all windows |
| `⌘⇧←` / `⌘⇧→` | Focus the window to the left / right |
| `⌘,` | Settings |

## Notes

- The Mac app and the menu bar app are distributed directly rather than through the App Store, and are signed ad-hoc. macOS allows it because `curl` downloads carry no quarantine flag. If you download a release asset with a browser instead, macOS will block it.
- `install.sh`, `install.ps1` and this README are mirrored here from the source repo. Don't edit them in this repo — changes will be overwritten on the next release.
