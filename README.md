# vision-claude

Run Claude Code on your Mac or Windows PC, drive it from Vision Pro or from a native Mac app.

This repo is the public distribution channel — it hosts the installer and release builds only. The source lives in a private repo.

**[UI design showcase →](https://echoulen.github.io/vision-claude-macos/)**

## Requirements

- **Mac** — Apple Silicon, with the Claude Code CLI already installed and logged in
- **Windows PC** (optional, to run sessions there) — Windows 10 version 1803 or later / Windows 11, 64-bit. Git for Windows and Claude Code are installed for you if missing.

## Install on a Mac

```bash
curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh | bash
```

One command sets up both pieces:

| | |
|---|---|
| **Server** | `~/.vision-claude/server` — runs as a launchd service, starts at login |
| **Mac app** | `/Applications/VisionClaude.app` |

Nothing to clone, no Node or Xcode required.

Re-run the same command to update. Your settings, tokens and session history live in `~/.vision-claude/` and are never touched by an update.

To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh | bash -s -- --uninstall
```

## Install on Windows

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
| **Server** | `%USERPROFILE%\.vision-claude\server` — starts hidden whenever this Windows account signs in |
| **Firewall** | Opens TCP 8790 for private networks. This is the only step that asks for administrator approval (one UAC prompt) |

- Everything is installed for the Windows account that runs the command. If several accounts should serve the Mac, run it once in each; only one of them can be signed in and serving at a time.
- Your network must be set to **Private** (Settings → Network & internet), otherwise the Mac can't reach the PC.
- If Claude Code was just installed, sign in once by running `claude` in a new terminal, or from the Claude account section of the Mac app's settings after pairing.

Re-run the same command to update. Config and session history in `%USERPROFILE%\.vision-claude\` are kept.

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

- **Mac** — open the URL in a browser on this Mac. It launches the app you just installed.
- **Vision Pro** — open the same page in the Vision Pro browser, replacing `127.0.0.1` with this Mac's LAN IP. Both devices must be on the same network.
- **Windows server** — the Windows installer prints `http://<PC's LAN IP>:8790/pair`. Open it in a browser on the Mac, click **Yes** on the dialog that appears on the PC, then **Open in App**.
  For now the Mac app talks to one server at a time: pairing with the PC switches the app over to it, and pairing again with the Mac's own URL switches it back.

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

- The Mac app is distributed directly rather than through the App Store, and is signed ad-hoc. macOS allows it because `curl` downloads carry no quarantine flag. If you download a release asset with a browser instead, macOS will block it.
- `install.sh`, `install.ps1` and this README are mirrored here from the source repo. Don't edit them in this repo — changes will be overwritten on the next release.
