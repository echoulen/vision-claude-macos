# vision-claude server installer / updater / uninstaller for Windows (x64).
#
#   PowerShell (a normal, non-administrator window):
#     irm https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1 | iex
#   cmd:
#     curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1 -o "%TEMP%\vc-install.ps1" && powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\vc-install.ps1"
#   Uninstall:
#     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1))) -Uninstall
#
# Installs Git for Windows (winget) and the native Claude Code if they're missing (asks first) ->
# downloads the release bundle -> installs to %USERPROFILE%\.vision-claude\server -> writes config ->
# opens the firewall (Private profile only) -> starts a hidden supervisor now and at every logon ->
# waits for /health -> prints the pairing URL. Rerunning the same line updates in place.
#
# Everything is installed for the account running this script, and runs only while that account is
# signed in. Each Windows account that should serve the Mac runs the installer once. Only the
# firewall rule needs administrator rights: it is created by a small separate elevated step (one
# UAC prompt), so answering UAC with a different administrator account can't redirect the install
# into that account's profile.
#
# Never call `exit` in here: under `irm | iex` it would close the user's PowerShell window.
# Fatal errors `throw` instead.
param(
  [switch]$Uninstall,
  # Local release archive instead of downloading the latest release (testing).
  [string]$Tarball = $env:VC_TARBALL,
  # Alternative dist repo (testing).
  [string]$DistRepoOverride = $env:VC_DIST_REPO
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$DistRepo      = if ($DistRepoOverride) { $DistRepoOverride } else { 'echoulen/vision-claude-macos' }
# Per account: several Windows accounts on one PC can each have their own install and rule.
$FirewallRule  = "VisionClaude Server ($env:USERDOMAIN\$env:USERNAME)"
# v0.7.0 used a logon task and one machine-wide rule name; both are migrated away on (re)install.
$LegacyTask    = 'VisionClaudeServer'
$LegacyRule    = 'VisionClaude Server'
$RunKey        = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName       = 'VisionClaudeServer'
$AssetName     = 'vision-claude-server-windows-x64.tar.gz'
$DataDir       = Join-Path $env:USERPROFILE '.vision-claude'
$ServerDir     = Join-Path $DataDir 'server'
$SupervisorDir = Join-Path $DataDir 'supervisor'
$LogFile       = Join-Path $DataDir 'logs\server.log'
$ConfigPath    = Join-Path $DataDir 'config.json'
# System32 bsdtar: a GNU tar from Git for Windows earlier on PATH treats "C:" as a remote host.
$Tar           = Join-Path $env:SystemRoot 'System32\tar.exe'
$ServerExe     = Join-Path $ServerDir 'VisionClaudeServer.exe'
$TrayDir       = Join-Path $DataDir 'tray'
$TrayExe       = Join-Path $TrayDir 'VisionClaudeTray.exe'
# Not every account has a real Start Menu\Programs folder (e.g. some service/redirected profiles);
# GetFolderPath can come back empty, so this is computed once here and checked before use below.
$ProgramsDir   = [Environment]::GetFolderPath('Programs')
$Curl          = Join-Path $env:SystemRoot 'System32\curl.exe'
# Parallel connections for the release download, see Save-WithCurl.
$DownloadParts = 8

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [ok] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Die($m)  { Restore-QuickEdit; throw "vision-claude install failed: $m" }

# The console's QuickEdit mode freezes all output the moment the user clicks inside the window
# (it starts a text selection) until Enter/Esc is pressed, which looks exactly like the installer
# hanging. Turn it off for the duration of the install and put the window back as it was at the
# end (or on failure), since under `irm | iex` this is the user's own PowerShell window.
$script:SavedConsoleMode = $null
function Disable-QuickEdit {
  try {
    if (-not ('VisionClaude.VcConsole' -as [type])) {
      Add-Type -Namespace VisionClaude -Name VcConsole -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint mode);
'@
    }
    $h = [VisionClaude.VcConsole]::GetStdHandle(-10)  # STD_INPUT_HANDLE
    [uint32]$mode = 0
    if (-not [VisionClaude.VcConsole]::GetConsoleMode($h, [ref]$mode)) { return }  # not a real console (ISE etc.)
    $script:SavedConsoleMode = $mode
    # ENABLE_EXTENDED_FLAGS (0x80) must be set for clearing ENABLE_QUICK_EDIT_MODE (0x40) to stick.
    [void][VisionClaude.VcConsole]::SetConsoleMode($h, [uint32](($mode -bor 0x80) -band 0xFFFFFFBF))
  } catch { }
}
function Restore-QuickEdit {
  if ($null -eq $script:SavedConsoleMode) { return }
  try { [void][VisionClaude.VcConsole]::SetConsoleMode([VisionClaude.VcConsole]::GetStdHandle(-10), $script:SavedConsoleMode) } catch { }
  $script:SavedConsoleMode = $null
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Kill the tray, then the supervisor so it can't respawn the server, then anything still running
# from server\. taskkill /T also takes down the claude processes the server started.
function Stop-VisionClaude {
  # The tray first: it starts the supervisor when launched, and holds tray\ open.
  Get-Process -Name VisionClaudeTray -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($TrayDir, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { & cmd.exe /c "taskkill /F /PID $($_.Id) >nul 2>&1" }

  foreach ($dir in @($SupervisorDir, $ServerDir)) {
    Get-Process -Name VisionClaudeServer -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) } |
      ForEach-Object {
        # Run through cmd.exe rather than piping taskkill's stderr through PowerShell: under
        # EAP=Stop, redirecting a native command's stderr wraps each line as a terminating
        # NativeCommandError, and taskkill routinely prints "not found" when part of the process
        # tree already exited. Exit code is ignored on purpose.
        & cmd.exe /c "taskkill /T /F /PID $($_.Id) >nul 2>&1"
      }
  }
  Start-Sleep -Seconds 1
}

# PowerShell single-quoted literal, for baking values into the elevated script below.
function Quote($s) { "'" + ($s -replace "'", "''") + "'" }

# Runs $script with administrator rights and reports whether it succeeded. Already elevated: runs
# in place. Otherwise: one UAC prompt for a hidden child PowerShell. The child may belong to a
# different (administrator) account, so $script must not rely on $env:USERPROFILE and friends;
# callers bake every value in with Quote. -EncodedCommand sidesteps Start-Process's unquoted
# argument joining in PS 5.1.
function Invoke-Elevated($script) {
  if (Test-Admin) {
    try { $null = & ([scriptblock]::Create($script)); return $true } catch { Warn $_.Exception.Message; return $false }
  }
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ErrorActionPreference = 'Stop'`n" + $script))
  try {
    $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    return ($p.ExitCode -eq 0)
  } catch {
    return $false  # UAC declined
  }
}

# Machine-wide leftovers of a v0.7.0 install *of this account* (task and rule pointing into this
# profile). Other accounts' installs are left alone.
function Get-LegacyCleanupScript {
  $data = Quote $DataDir
  @"
`$data = $data
`$task = Get-ScheduledTask -TaskName $(Quote $LegacyTask) -ErrorAction SilentlyContinue
if (`$task -and (`$task.Actions | Where-Object { `$_.Arguments -and `$_.Arguments.IndexOf(`$data, [StringComparison]::OrdinalIgnoreCase) -ge 0 })) {
  Unregister-ScheduledTask -TaskName $(Quote $LegacyTask) -Confirm:`$false
}
foreach (`$r in @(Get-NetFirewallRule -DisplayName $(Quote $LegacyRule) -ErrorAction SilentlyContinue)) {
  `$program = (Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule `$r).Program
  if (`$program -and `$program.StartsWith(`$data, [StringComparison]::OrdinalIgnoreCase)) {
    `$r | Remove-NetFirewallRule
  }
}
Get-NetFirewallRule -DisplayName $(Quote $FirewallRule) -ErrorAction SilentlyContinue | Remove-NetFirewallRule
"@
}

# Remove-Item on a just-stopped process's directory can fail transiently while Windows releases
# file handles or Defender finishes scanning; retry instead of failing the whole install/uninstall.
function Remove-DirWithRetry($path) {
  if (-not (Test-Path $path)) { return }
  for ($i = 0; $i -lt 10; $i++) {
    try {
      Remove-Item -Recurse -Force $path -ErrorAction Stop
      return
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }
  Die "Could not remove $path (still in use). Close any programs using it and try again."
}

function Invoke-Uninstall {
  Info 'Uninstalling vision-claude server'
  # Hooks first: they point at server\VisionClaudeServer.exe, and once that's gone every claude
  # session on this machine would report a hook error.
  $hooksCli = Join-Path $ServerDir 'lib\hooks-cli.js'
  if ((Test-Path $ServerExe) -and (Test-Path $hooksCli)) {
    & $ServerExe $hooksCli uninstall
    if ($LASTEXITCODE -ne 0) {
      Warn "Could not remove the claude hooks automatically. Delete the __vision_claude_hook entries from %USERPROFILE%\.claude\settings.json yourself."
    }
  }
  Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
  if ($ProgramsDir) {
    Remove-Item -LiteralPath (Join-Path $ProgramsDir 'VisionClaude.lnk') -ErrorAction SilentlyContinue
  }
  Stop-VisionClaude
  Info 'Removing the firewall rule (administrator approval needed)'
  if (-not (Invoke-Elevated (Get-LegacyCleanupScript))) {
    Warn "Couldn't remove the firewall rule '$FirewallRule'. Remove it in Windows Defender Firewall yourself if you like; it's harmless without the program."
  }
  foreach ($dir in @($ServerDir, $SupervisorDir, $TrayDir, (Join-Path $DataDir 'server.new'), (Join-Path $DataDir 'server.old'))) {
    Remove-DirWithRetry $dir
  }
  Ok 'Removed autostart, firewall rule and program files'
  Write-Host "   Config and session data remain in $DataDir (delete that folder yourself if you want them gone too)"
}

# Start menu shortcut so the tray app (and the window it can show) is reachable without remembering
# this install lives under %USERPROFILE%\.vision-claude\tray. Recreated every install; a broken COM
# call here shouldn't fail the whole install, just leave the shortcut missing.
function New-StartMenuShortcut {
  $shell = $null
  $link = $null
  try {
    if (-not $ProgramsDir) { Warn "Couldn't find the Start menu Programs folder; skipping the shortcut."; return }
    $lnkPath = Join-Path $ProgramsDir 'VisionClaude.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($lnkPath)
    $link.TargetPath = $TrayExe
    $link.Arguments = ''
    $link.WorkingDirectory = $TrayDir
    $link.IconLocation = "$TrayExe,0"
    $link.Description = 'VisionClaude server'
    $link.Save()
    Ok "Start menu shortcut: $lnkPath"
  } catch {
    Warn "Couldn't create the Start menu shortcut: $($_.Exception.Message)"
  } finally {
    if ($link) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link) }
    if ($shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
  }
}

# Default is yes: the user started an installer, so a bare Enter means "go ahead".
function Confirm-Install($prompt) {
  $answer = Read-Host "$prompt [Y/n]"
  return ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim() -match '^(y|yes)$')
}

# Installers only update the persisted PATH; this window keeps the one it started with.
function Update-SessionPath {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$machine;$user"
}

# Only the native claude.exe is supported (npm's claude.cmd needs a shell to start, which breaks
# process-tree handling). -All because PATH may hold claude.cmd ahead of claude.exe. The official
# installer puts it in ~\.local\bin, which may not be on this window's PATH yet.
function Find-NativeClaude {
  $exe = Get-Command claude -All -CommandType Application -ErrorAction SilentlyContinue |
    Where-Object { [IO.Path]::GetExtension($_.Source) -eq '.exe' } | Select-Object -First 1
  if ($exe) { return $exe.Source }
  $default = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
  if (Test-Path $default) { return $default }
  return $null
}

# Pin "latest" to its tag once, so every range below comes from the same release even if a new one
# is published mid-download. Falls back to the /latest/ URL if the lookup fails (Save-WithCurl then
# reports why curl can't connect).
function Resolve-ReleaseAssetUrl {
  $latest = "https://github.com/$DistRepo/releases/latest/download/$AssetName"
  if (-not (Test-Path $Curl)) { return $latest }
  $resolved = & $Curl -sLIf --connect-timeout 30 -o NUL -w '%{url_effective}' "https://github.com/$DistRepo/releases/latest"
  if ($LASTEXITCODE -eq 0 -and $resolved -match '/releases/tag/([^/?#]+)$') {
    return "https://github.com/$DistRepo/releases/download/$($Matches[1])/$AssetName"
  }
  return $latest
}

# curl arguments shared by every download: follow GitHub's redirect to its CDN, fail on HTTP errors,
# and abort a transfer that stalls below 1 KB/s for a minute so --retry can start it again.
$CurlCommon = @('-L', '-f', '--retry', '5', '--retry-delay', '2', '--connect-timeout', '30', '-y', '60', '-Y', '1024')

# GitHub's release CDN can throttle each connection to tens of KB/s, so even curl's single stream
# took ~8 minutes for the ~33 MB asset. Instead: ask for byte 0 to learn the size, fetch
# $DownloadParts ranges with parallel curl.exe processes while printing progress, then join them.
# A server that ignores Range gets one curl with its own progress bar. Returns $false (after a
# warning) when curl can't do it, so the caller can fall back to Invoke-WebRequest.
function Save-WithCurl($url, $dest) {
  $headers = & $Curl -sS @CurlCommon -r 0-0 -o NUL -D - $url
  if ($LASTEXITCODE -ne 0) {
    Warn "curl failed (exit code $LASTEXITCODE)"
    return $false
  }
  $size = 0
  $m = [regex]::Matches(($headers -join "`n"), '(?im)^content-range:\s*bytes\s+0-0/(\d+)')
  if ($m.Count -gt 0) { $size = [long]$m[$m.Count - 1].Groups[1].Value }
  if ($size -le 0) {
    & $Curl @CurlCommon -# -o $dest $url
    if ($LASTEXITCODE -ne 0) { Warn "curl failed (exit code $LASTEXITCODE)"; return $false }
    return $true
  }

  $chunk = [long][math]::Ceiling($size / $DownloadParts)
  $parts = @()
  for ($start = [long]0; $start -lt $size; $start += $chunk) {
    $end = [math]::Min($start + $chunk, $size) - 1
    $parts += [pscustomobject]@{ Range = "$start-$end"; Length = $end - $start + 1; Path = "$dest.part$($parts.Count)"; Proc = $null }
  }
  $mb = { param($bytes) '{0:N1}' -f ($bytes / 1MB) }
  try {
    foreach ($p in $parts) {
      $psi = New-Object Diagnostics.ProcessStartInfo $Curl
      $psi.Arguments = (@('-s') + $CurlCommon + @('-r', $p.Range, '-o', "`"$($p.Path)`"", "`"$url`"")) -join ' '
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $p.Proc = [Diagnostics.Process]::Start($psi)
    }
    while (@($parts | Where-Object { -not $_.Proc.HasExited }).Count -gt 0) {
      $got = [long]0
      foreach ($p in $parts) { $f = New-Object IO.FileInfo $p.Path; if ($f.Exists) { $got += $f.Length } }
      Write-Host -NoNewline ("`r    {0} / {1} MB ({2}%)   " -f (& $mb $got), (& $mb $size), [int](100 * $got / $size))
      Start-Sleep -Milliseconds 500
    }
    Write-Host ("`r    {0} / {0} MB (100%)   " -f (& $mb $size))

    # A range that still failed after curl's own retries gets one more try in the foreground,
    # where curl's error message is visible.
    foreach ($p in $parts) {
      $ok = $p.Proc.ExitCode -eq 0 -and (Test-Path $p.Path) -and (Get-Item $p.Path).Length -eq $p.Length
      if (-not $ok) {
        & $Curl -sS @CurlCommon -r $p.Range -o $p.Path $url
        if ($LASTEXITCODE -ne 0 -or (Get-Item $p.Path).Length -ne $p.Length) {
          Warn "curl failed on bytes $($p.Range) (exit code $LASTEXITCODE)"
          return $false
        }
      }
    }

    $out = [IO.File]::Create($dest)
    try {
      foreach ($p in $parts) {
        $in = [IO.File]::OpenRead($p.Path)
        try { $in.CopyTo($out) } finally { $in.Dispose() }
      }
    } finally { $out.Dispose() }
  } finally {
    # Ctrl+C or a failure above: don't leave curl processes writing into the temp folder.
    foreach ($p in $parts) {
      if ($p.Proc -and -not $p.Proc.HasExited) { try { $p.Proc.Kill() } catch { } }
    }
    foreach ($p in $parts) { Remove-Item $p.Path -Force -ErrorAction SilentlyContinue }
  }
  if ((Get-Item $dest).Length -ne $size) {
    Warn "curl download is $((Get-Item $dest).Length) bytes, expected $size"
    return $false
  }
  return $true
}

function Get-LanAddresses {
  Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
      $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and
      $_.InterfaceAlias -notmatch 'vEthernet|WSL|Hyper-V|VirtualBox|VMware|Tailscale|ZeroTier|Bluetooth|Npcap|Loopback'
    } |
    Select-Object -ExpandProperty IPAddress
}

# 32-bit PowerShell on 64-bit Windows sees SysWOW64 in place of System32 (no conhost.exe there).
if (-not [Environment]::Is64BitProcess) { Die 'Run this in the 64-bit Windows PowerShell (not "Windows PowerShell (x86)").' }

# An elevated window is the one way left to install into the wrong place: "Run as administrator"
# with another account's password makes $env:USERPROFILE and HKCU that account's, and the server
# would then only start when *that* account signs in. Compare with the owner of this desktop's
# explorer.exe. Same account but elevated still works, but everything started from here (the
# tray app, the server and every claude it runs) keeps administrator rights until sign-out, so warn.
if (Test-Admin) {
  $session = (Get-Process -Id $PID).SessionId
  $shell = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$session" -ErrorAction SilentlyContinue |
    Select-Object -First 1
  $owner = if ($shell) { Invoke-CimMethod -InputObject $shell -MethodName GetOwnerSid -ErrorAction SilentlyContinue } else { $null }
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if ($owner -and $owner.Sid -and $owner.Sid -ne $me) {
    Die "This administrator window runs as $env:USERNAME, not the account signed in to this desktop, so it would install into the wrong profile. Run the line in a normal (non-administrator) PowerShell window instead; it asks for administrator approval only for the firewall rule."
  }
  Warn 'Running in an administrator window: until you sign out, the tray app, the server and Claude run with administrator rights, and a later reinstall from a normal window may fail to replace them. A normal PowerShell window is recommended.'
}

Disable-QuickEdit
if ($Uninstall) { Invoke-Uninstall; Restore-QuickEdit; return }

# -- Environment checks ------------------------------------------------------
if (-not [Environment]::Is64BitOperatingSystem) { Die '64-bit Windows is required.' }
if (-not (Test-Path $Tar)) { Die "tar.exe not found at $Tar (Windows 10 version 1803 or later is required)." }

# A fresh machine gets its prerequisites installed here (after a [Y/n] prompt) instead of being sent
# off to install them by hand. Git first: Claude Code on Windows runs its shell through Git Bash.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Die 'git not found and winget is unavailable. Install Git for Windows from https://git-scm.com/download/win, then rerun.'
  }
  if (-not (Confirm-Install 'Git for Windows (required by Claude Code) is not installed. Install it now with winget?')) {
    Die 'Git for Windows is required. Install it from https://git-scm.com/download/win, then rerun.'
  }
  Info 'Installing Git for Windows with winget'
  & winget install --id Git.Git -e --source winget --silent --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0) {
    Die "winget couldn't install Git (exit code $LASTEXITCODE). Install it from https://git-scm.com/download/win, then rerun."
  }
  Update-SessionPath
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "Git was installed but git.exe still isn't on PATH. Open a new PowerShell window and rerun."
  }
}
Ok "git: $((Get-Command git).Source)"

$ClaudeInstalledNow = $false
$ClaudeBin = Find-NativeClaude
if (-not $ClaudeBin) {
  $other = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
  $prompt = if ($other) {
    "Only $($other.Source) was found; vision-claude needs the native claude.exe. Install native Claude Code now?"
  } else {
    'Claude Code is not installed. Install it now?'
  }
  if (-not (Confirm-Install $prompt)) {
    Die 'The native Claude Code is required. Install it with:  irm https://claude.ai/install.ps1 | iex'
  }
  Info 'Installing Claude Code with the official installer'
  # The official installer is itself an `irm | iex` script. Running it in a child PowerShell keeps an
  # `exit` inside it from ending this install and keeps its variables out of ours.
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command 'irm https://claude.ai/install.ps1 | iex'
  Update-SessionPath
  $ClaudeBin = Find-NativeClaude
  if (-not $ClaudeBin) {
    Die "Claude Code's installer finished but claude.exe wasn't found. Install it manually with:  irm https://claude.ai/install.ps1 | iex"
  }
  $ClaudeInstalledNow = $true
}
Ok "claude CLI: $ClaudeBin"

# -- Download and swap program files -----------------------------------------
# Staged under $DataDir (not %TEMP%) so the final Move-Item into $ServerDir never crosses volumes.
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$Tmp = Join-Path $DataDir ("install-tmp-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  if ($Tarball) {
    $TarPath = $Tarball
    Info "Using local archive $TarPath"
  } else {
    $TarPath = Join-Path $Tmp $AssetName
    $Url = Resolve-ReleaseAssetUrl
    Info "Downloading $AssetName"
    # curl.exe (built into Windows 10 1803+) shows progress and, in parallel ranges, is far faster
    # than PS 5.1's Invoke-WebRequest, which on a ~35 MB file looks exactly like a hang.
    if (-not ((Test-Path $Curl) -and (Save-WithCurl $Url $TarPath))) {
      # e.g. curl exit 35 behind TLS-inspecting proxies (Schannel revocation check); the .NET stack
      # usually copes, so fall back instead of failing outright.
      if (Test-Path $Curl) { Warn 'Retrying with Invoke-WebRequest (no progress shown, may take a while)' }
      Invoke-WebRequest -Uri $Url -OutFile $TarPath -UseBasicParsing
    }
  }
  & $Tar -xzf $TarPath -C $Tmp
  if ($LASTEXITCODE -ne 0) { Die 'Failed to extract the archive; the download may be incomplete.' }
  $Staged = Join-Path $Tmp 'vision-claude-server'
  foreach ($f in @('VisionClaudeServer.exe', 'VERSION', 'lib\server.js', 'lib\supervisor.js', 'tray\VisionClaudeTray.exe')) {
    if (-not (Test-Path (Join-Path $Staged $f))) { Die "Release archive is missing $f." }
  }

  Info 'Stopping the previous service (if any)'
  Stop-VisionClaude

  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  foreach ($dir in @($ServerDir, $SupervisorDir, $TrayDir)) {
    Remove-DirWithRetry $dir
  }
  Move-Item $Staged $ServerDir
  New-Item -ItemType Directory -Path $SupervisorDir | Out-Null
  Copy-Item $ServerExe $SupervisorDir
  Copy-Item (Join-Path $ServerDir 'lib\supervisor.js') $SupervisorDir
  # The tray lives outside the versioned server\ dir so server self-updates leave it alone.
  Move-Item (Join-Path $ServerDir 'tray') $TrayDir
  $Version = ([IO.File]::ReadAllText((Join-Path $ServerDir 'VERSION'))).Trim()
  # The tray compares this with server\VERSION after a server self-update to decide whether it
  # must replace itself with the tray bundled in the new server\tray (UTF-8 without BOM).
  [IO.File]::WriteAllText((Join-Path $TrayDir 'VERSION'), $Version, (New-Object Text.UTF8Encoding $false))
  Ok "Installed to $ServerDir (version $Version)"
} finally {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

# -- Config ------------------------------------------------------------------
# The token isn't generated here: the server adds a random one on first start and the pairing page
# hands it to the App. Existing configs only get claudeBin refreshed and `models` dropped (the
# server's built-in list is the source of truth), same as install.sh.
if (Test-Path $ConfigPath) {
  # Get-Content -Raw decodes via the system ANSI code page in PS 5.1, which corrupts the UTF-8
  # (no BOM) file we write below whenever it holds non-ASCII text (e.g. a non-English user name
  # in projectsRoot). Read the bytes as UTF-8 explicitly instead.
  $cfg = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
  $cfg | Add-Member -NotePropertyName claudeBin -NotePropertyValue $ClaudeBin -Force
  if ($cfg.PSObject.Properties['models']) { $cfg.PSObject.Properties.Remove('models') }
} else {
  $defaultRoot = Join-Path $env:USERPROFILE 'work'
  $answer = Read-Host "Projects folder (where your Unreal projects live) [$defaultRoot]"
  $cfg = [pscustomobject]@{ claudeBin = $ClaudeBin; bind = @('127.0.0.1', 'lan') }
  # Pressing Enter accepts the default, so leave projectsRoot out and let the server resolve it
  # (%USERPROFILE%\work when it exists, otherwise the home folder). Writing the default here would
  # mark the install as "configured" and the tray would never offer to set the folder up.
  if (-not [string]::IsNullOrWhiteSpace($answer)) {
    $projectsRoot = $answer.Trim().Trim('"')
    if (-not (Test-Path $projectsRoot)) { Warn "$projectsRoot doesn't exist yet; create it or edit projectsRoot in $ConfigPath" }
    $cfg | Add-Member -NotePropertyName projectsRoot -NotePropertyValue $projectsRoot
  } elseif (-not (Test-Path $defaultRoot)) {
    Info "No projects folder yet: open Vision Claude from the system tray and pick one with CHOOSE FOLDER."
  }
}
$Port = if ($cfg.PSObject.Properties['port']) { [int]$cfg.port } else { 8790 }
# PS 5.1 known issue: ConvertTo-Json can serialize arrays as {"value":[...],"Count":N} instead of
# a plain JSON array once System.Array picks up an ETS type extension; drop it before converting.
Remove-TypeData System.Array -ErrorAction SilentlyContinue
# UTF-8 without BOM: Node's JSON.parse chokes on a BOM.
[IO.File]::WriteAllText($ConfigPath, ($cfg | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
Ok "Config: $ConfigPath"

# -- Firewall ----------------------------------------------------------------
# Before the server starts, so Windows never pops its own "allow access" dialog for it.
Info 'Opening the firewall for your Mac (administrator approval needed)'
$firewallScript = (Get-LegacyCleanupScript) + @"

New-NetFirewallRule -DisplayName $(Quote $FirewallRule) -Direction Inbound -Action Allow -Protocol TCP ``
  -LocalPort $Port -Program $(Quote $ServerExe) -Profile Private | Out-Null
"@
if (Invoke-Elevated $firewallScript) {
  Ok "Firewall: TCP $Port open on Private networks"
} else {
  Warn "Administrator approval didn't go through: the firewall rule wasn't created (your Mac can't reach this PC yet) and any logon task left by v0.7.0 wasn't removed. Rerun the installer and approve the prompt."
}
$public = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Public' }
if ($public) {
  Warn "Network '$($public[0].Name)' is set to Public, so your Mac can't reach this PC. Switch it to Private in Settings > Network & internet."
}

# -- Start menu shortcut ------------------------------------------------------
New-StartMenuShortcut

# -- Autostart ---------------------------------------------------------------
# A per-user Run value rather than a scheduled task: needs no administrator rights and always runs
# in this account's own session, whichever account answered UAC above. It launches the tray app,
# which starts the server (and lets the user stop / start it and copy the pairing link).
# --background: this is an unattended launch (login, or the installer itself below), not the user
# opening the app, so it should start silently instead of popping the status window.
Set-ItemProperty -Path $RunKey -Name $RunName -Value "`"$TrayExe`" --background"
Start-Process -FilePath $TrayExe -WorkingDirectory $TrayDir -ArgumentList '--background'
Ok "Starts automatically when $env:USERNAME signs in (VisionClaude icon in the system tray)"

# -- Health check ------------------------------------------------------------
Info "Waiting for the server on port $Port"
$healthy = $false
for ($i = 0; $i -lt 30; $i++) {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 2
    if ($r.StatusCode -eq 200) { $healthy = $true; break }
  } catch { }
  Start-Sleep -Seconds 1
}
if (-not $healthy) {
  if (Test-Path $LogFile) { Write-Host 'Last lines of the server log:'; Get-Content $LogFile -Tail 20 }
  Die "The server didn't come up within 30 seconds. Check $LogFile"
}
# /health answering doesn't prove it's *this* install: another signed-in account's server (or
# anything else) may hold the port, in which case ours can't listen and the Mac would pair with
# the other one. Another account's process has no readable Path, which also counts as "not ours".
$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
$listenerPath = if ($listener) { (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).Path } else { $null }
if (-not $listenerPath -or -not $listenerPath.StartsWith($ServerDir, [StringComparison]::OrdinalIgnoreCase)) {
  Die "Port $Port is held by another program or by vision-claude of another signed-in Windows account. Sign that account out (or uninstall it there) and rerun."
}
Ok 'Server is running'

Write-Host ''
Write-Host 'Pair your Mac: open one of these in a browser on the Mac, then click Yes on this PC:'
foreach ($ip in (Get-LanAddresses)) { Write-Host "   http://${ip}:$Port/pair" }
Write-Host ''
Write-Host "Logs: $LogFile"
Write-Host 'The VisionClaude icon in the system tray can stop / start the server and copy the pairing link.'
Write-Host 'Open it any time from the Start menu: VisionClaude.'
if ($ClaudeInstalledNow) {
  Write-Host ''
  Write-Host 'Claude Code was just installed and still needs you to sign in: run `claude` in a new terminal,'
  Write-Host 'or use the Claude account section in the App settings after pairing.'
}

Restore-QuickEdit
