# vision-claude

Run Claude Code on your Mac or Windows PC, drive it from a native Mac app or from Vision Pro.

## Install

Three pieces, one line each. Pick the ones for what that machine should do — a Mac can be both a server and an app.

| Role | Command |
|---|---|
| Mac server + menu bar app | `curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh \| bash -s -- --server` |
| Mac / Vision Pro app | `curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh \| bash -s -- --app` |
| Windows server | `irm https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1 \| iex` |

Nothing to clone, no Node or Xcode required. On Vision Pro the app comes from TestFlight.

## First run

1. **Pair.** When a server install finishes it prints a pairing URL — `http://127.0.0.1:8790/pair` on a Mac, `http://<PC's LAN IP>:8790/pair` on Windows. Open it in a browser on the Mac (or Vision Pro, using the server's LAN IP) and click **Open in App**; the address and token are handed over, nothing to type. You can also grab the link any time from the menu bar app (Mac) or the tray app (Windows). Each device pairs once; the app can stay connected to several servers at once.
2. **Start a session.** Press **⌘N**, pick a project folder, and type. Each session is its own window and keeps running in the background.

<details>
<summary>Keyboard shortcuts</summary>

| | |
|---|---|
| `⌘N` | New session |
| `⌘0` | Session list |
| `⌘1`–`⌘9` | Jump to a session |
| `⌥⌘V` | Bring Vision Claude to front from any app |
| `⌘⇧G` | Tile all windows |
| `⌘⇧←` / `⌘⇧→` | Focus the window to the left / right |
| `⌘,` | Settings |

</details>

<details>
<summary>Reaching a server from outside your network (Tailscale)</summary>

The server only speaks plain HTTP on your LAN. To use it from elsewhere, connect your devices with [Tailscale](https://tailscale.com) (the free Personal plan is enough) and publish the server to your tailnet only. Never expose it to the public internet: a server token lets whoever holds it run Claude Code on that machine.

1. Install Tailscale on the server machine (version 1.104.4 or later) and on each device you connect from, and sign in to the same account. On the server machine, turn on **Launch at login** so the connection comes back after a restart.
2. Publish the server to your tailnet, on the server machine:

   ```bash
   tailscale serve --bg 8790
   ```

   If `tailscale` isn't on your PATH, use `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. The first run may print a link to enable Serve for your tailnet (this also turns on HTTPS certificates); open it, then run the command again. The first request after that can time out while the certificate is issued, so retry it.

   Do not use `tailscale funnel`, which makes it public. Certificate names are published in a public log, so avoid sensitive machine names.
3. Pair through the tailnet: open `https://<machine>.<tailnet>.ts.net/pair` and approve the request on the server machine (the dialog shows your Tailscale address, marked *via tunnel*).

</details>

<details>
<summary>Using it from your iPhone</summary>

After setting up Tailscale above, install Tailscale on your iPhone and, while you're next to your Mac:

1. Open `https://<machine>.<tailnet>.ts.net` in Safari and add it to your Home Screen.
2. Open it from the Home Screen icon and tap **Pair this phone**, then approve the request on your Mac.
3. Set up Face ID and turn on notifications.

You'll get a notification only when an agent is waiting on you.

</details>

## Screenshots

*Design renders from the UI mockup — this is what the app looks like.*

Every session is one Claude Code conversation bound to a folder, on any server you've paired.

![Session list](images/session-list.png)

Chat with tool calls, thinking and streaming output inline.

![Chat](images/chat.png)

Review the diff Claude just wrote without leaving the window.

![Diff](images/diff.png)

Start a session: pick a server, a project folder and a branch or worktree.

![New session](images/new-session.png)

Pair and manage every server — Mac or Windows — from the app's settings.

![Settings · servers](images/settings-servers.png)

On a Mac the server lives in the menu bar — status, pairing link, logs, updates; on Windows the same panel lives in the system tray.

![macOS menu bar](images/macos-menu-bar.png)

**[Full UI design showcase →](https://echoulen.github.io/vision-claude-macos/)**

## Updates

The app updates itself from **Settings → App**. Each server updates from the app's **Settings → Servers**, or on that machine from the menu bar app (Mac) or the tray app (Windows). The Vision Pro app updates through TestFlight.

<details>
<summary>Requirements and uninstall</summary>

**Requirements** — a Mac (Apple Silicon or Intel) on macOS 26 or later; the Claude Code CLI installed and logged in on whichever machine runs the server (the app alone doesn't need it). For a Windows server: Windows 10 1803+ / Windows 11, 64-bit, on a network set to **Private**; Git for Windows and Claude Code are installed for you if missing.

**Uninstall on macOS** (removes the server, the menu bar app and the Mac app, keeping `~/.vision-claude/`):

```bash
curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.sh | bash -s -- --uninstall
```

**Uninstall on Windows** (in a normal PowerShell window; keeps `%USERPROFILE%\.vision-claude\`):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1))) -Uninstall
```

This repo is the public distribution channel — installers and release builds only; the source lives in a private repo. `install.sh`, `install.ps1`, this README and `images/` are mirrored here on each release, so don't edit them here.

</details>
