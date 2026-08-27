# vision-claude

Run Claude Code on your Mac, drive it from Vision Pro or from a native Mac app.

This repo is the public distribution channel — it hosts the installer and release builds only. The source lives in a private repo.

**[UI design showcase →](https://echoulen.github.io/vision-claude-macos/)**

## Requirements

- Mac with Apple Silicon
- Claude Code CLI, already installed and logged in

## Install

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

## Getting started

### 1. Pair your devices

When the install finishes it prints a pairing URL:

```
http://127.0.0.1:8790/pair
```

Open it and click **Open in App**. The server address and token are handed over automatically — nothing to type or copy.

- **Mac** — open the URL in a browser on this Mac. It launches the app you just installed.
- **Vision Pro** — open the same page in the Vision Pro browser, replacing `127.0.0.1` with this Mac's LAN IP. Both devices must be on the same network.

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

## Maintenance

```bash
# Restart the server
launchctl kickstart -k gui/$(id -u)/io.nextdrive.vision-claude-server

# Tail the log
tail -f ~/Library/Logs/vision-claude-server.err.log

# Uninstall (removes the server, the service and the Mac app)
curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh | bash -s -- --uninstall
```

Settings and session history in `~/.vision-claude/` survive an uninstall. Delete that folder to remove them too.

## Notes

- The Mac app is distributed directly rather than through the App Store, and is signed ad-hoc. macOS allows it because `curl` downloads carry no quarantine flag. If you download a release asset with a browser instead, macOS will block it.
- `install.sh` is mirrored here from the source repo. Don't edit it in this repo — changes will be overwritten on the next release.
