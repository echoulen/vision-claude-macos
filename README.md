# vision-claude-dist

[vision-claude](https://github.com/echoulen/vision-claude) 的 Mac server 公開發佈鏡像。原始碼不在這裡，這個 repo 只放安裝腳本與各版本的發佈包。

## 安裝

在 Mac 的終端機貼上這行：

```bash
curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-dist/main/install.sh | bash
```

會下載自帶 node runtime 的發佈包到 `~/.vision-claude/server`、註冊成登入自啟的 launchd 服務，並印出配對網址。不需要 clone 任何 repo，也不需要先裝 node 或 pnpm——只需要 [Claude Code CLI](https://claude.ai/install.sh)。

- **更新**：重跑同一行
- **移除**：`curl -fsSL .../install.sh | bash -s -- --uninstall`
- **重啟**：`launchctl kickstart -k gui/$(id -u)/io.nextdrive.vision-claude-server`
- **看 log**：`tail -f ~/Library/Logs/vision-claude-server.err.log`

目前只提供 Apple Silicon（arm64）的發佈包。

## 內容

| 項目 | 說明 |
|---|---|
| `install.sh` | 安裝腳本。**唯一真實來源在 vision-claude repo**，由該 repo 的 Server Release workflow 同步過來，不要直接改這裡 |
| Releases | `vision-claude-server-macos-arm64.tar.gz`，自帶 node runtime |
