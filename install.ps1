# vision-claude server installer / updater / uninstaller for Windows (x64).
#
#   PowerShell (a normal window is fine; it asks for administrator rights once via UAC):
#     irm https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1 | iex
#   cmd:
#     curl -fsSL https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1 -o "%TEMP%\vc-install.ps1" && powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\vc-install.ps1"
#   Uninstall:
#     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/echoulen/vision-claude-macos/main/install.ps1))) -Uninstall
#
# Installs Git for Windows (winget) and the native Claude Code if they're missing (asks first) ->
# downloads the release bundle -> installs to %USERPROFILE%\.vision-claude\server -> writes config ->
# registers a logon task that runs a hidden supervisor -> opens the firewall (Private profile only) ->
# waits for /health -> prints the pairing URL. Rerunning the same line updates in place.
#
# Administrator is required for the logon task and the firewall rule; the task itself runs as the
# current user with normal (Limited) rights. When started without it, the script relaunches itself
# in a new elevated window (one UAC prompt) and the rest of the install happens there.
#
# Never call `exit` in here: under `irm | iex` it would close the user's PowerShell window.
# Fatal errors `throw` instead.
param(
  [switch]$Uninstall,
  # Local release archive instead of downloading the latest release (testing).
  [string]$Tarball = $env:VC_TARBALL,
  # Alternative dist repo (testing).
  [string]$DistRepoOverride = $env:VC_DIST_REPO,
  # Set by the self-elevation below: SID of the account that started the install before the UAC
  # prompt. A SID never contains spaces, so comparing it (instead of the display name) is safe
  # even when Start-Process joins -ArgumentList with spaces and no quoting.
  [string]$InvokedBySid = '',
  # Set by the self-elevation below: display name of that same account, for the error message only.
  [string]$InvokedByName = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$DistRepo      = if ($DistRepoOverride) { $DistRepoOverride } else { 'echoulen/vision-claude-macos' }
$TaskName      = 'VisionClaudeServer'
$FirewallRule  = 'VisionClaude Server'
$AssetName     = 'vision-claude-server-windows-x64.tar.gz'
$DataDir       = Join-Path $env:USERPROFILE '.vision-claude'
$ServerDir     = Join-Path $DataDir 'server'
$SupervisorDir = Join-Path $DataDir 'supervisor'
$LogFile       = Join-Path $DataDir 'logs\server.log'
$ConfigPath    = Join-Path $DataDir 'config.json'
# System32 bsdtar: a GNU tar from Git for Windows earlier on PATH treats "C:" as a remote host.
$Tar           = Join-Path $env:SystemRoot 'System32\tar.exe'
$ServerExe     = Join-Path $ServerDir 'VisionClaudeServer.exe'

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [ok] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Die($m)  { throw "vision-claude install failed: $m" }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Kill the supervisor first so it can't respawn the server, then anything still running from server\.
# taskkill /T also takes down the claude processes the server started.
function Stop-VisionClaude {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  }
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

function Remove-FirewallRule {
  Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
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
  Stop-VisionClaude
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-FirewallRule
  foreach ($dir in @($ServerDir, $SupervisorDir, (Join-Path $DataDir 'server.new'), (Join-Path $DataDir 'server.old'))) {
    Remove-DirWithRetry $dir
  }
  Ok 'Removed the logon task, firewall rule and program files'
  Write-Host "   Config and session data remain in $DataDir (delete that folder yourself if you want them gone too)"
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

function Get-LanAddresses {
  Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
      $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and
      $_.InterfaceAlias -notmatch 'vEthernet|WSL|Hyper-V|VirtualBox|VMware|Tailscale|ZeroTier|Bluetooth|Npcap|Loopback'
    } |
    Select-Object -ExpandProperty IPAddress
}

# Not elevated: relaunch in a new elevated window instead of making the user reopen PowerShell as
# administrator. Under `irm | iex` there is no script file to relaunch, so the same installer is
# fetched to a temp file first. The elevated process doesn't inherit this session's environment
# (UAC goes through ShellExecute), so the VC_* overrides travel as parameters, and a relative
# -Tarball is resolved now because the elevated window starts in System32.
if (-not (Test-Admin)) {
  $self = $PSCommandPath
  if (-not $self) {
    # Unpredictable name: a fixed one under a world-writable %TEMP% could be swapped out by
    # another process between this download and Start-Process reading it back (TOCTOU).
    $self = Join-Path ([IO.Path]::GetTempPath()) "vision-claude-install-$([guid]::NewGuid()).ps1"
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$DistRepo/main/install.ps1" -OutFile $self -UseBasicParsing
  }
  # Identify the invoking account by SID, not name: Windows PowerShell 5.1 joins -ArgumentList
  # with spaces and no quoting, and a display name like "John Smith" would otherwise be split in
  # two. A SID never contains spaces. The display name still travels (quoted) for the error
  # message below, which is human-readable but not security-relevant.
  $invokerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $argList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$self`"",
    '-InvokedBySid', $invokerSid, '-InvokedByName', "`"$env:USERNAME`""
  )
  if ($Uninstall) { $argList += '-Uninstall' }
  if ($Tarball) { $argList += @('-Tarball', "`"$((Resolve-Path $Tarball).Path)`"") }
  if ($DistRepoOverride) { $argList += @('-DistRepoOverride', "`"$DistRepoOverride`"") }
  Info 'Administrator rights are needed for the logon task and the firewall rule'
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
  } catch {
    Die 'Administrator rights were declined. Rerun and click Yes on the prompt, or run the line in an Administrator PowerShell.'
  }
  Ok 'Continuing in the new administrator window; follow it there'
  return
}

# A standard account elevates by typing another (admin) account's password; the elevated window
# then belongs to that account, and USERPROFILE / the logon task would point at the wrong user.
# Compare by SID (stable, never has spaces) rather than by name.
if ($InvokedBySid -and $InvokedBySid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
  Die "The administrator window runs as $env:USERNAME, not $InvokedByName, so it would install into the wrong profile. Make $InvokedByName an administrator (or sign in to Windows as one) and rerun."
}

if ($Uninstall) { Invoke-Uninstall; return }

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
    $Url = "https://github.com/$DistRepo/releases/latest/download/$AssetName"
    Info "Downloading $AssetName"
    Invoke-WebRequest -Uri $Url -OutFile $TarPath -UseBasicParsing
  }
  & $Tar -xzf $TarPath -C $Tmp
  if ($LASTEXITCODE -ne 0) { Die 'Failed to extract the archive; the download may be incomplete.' }
  $Staged = Join-Path $Tmp 'vision-claude-server'
  foreach ($f in @('VisionClaudeServer.exe', 'VERSION', 'lib\server.js', 'lib\supervisor.js')) {
    if (-not (Test-Path (Join-Path $Staged $f))) { Die "Release archive is missing $f." }
  }

  Info 'Stopping the previous service (if any)'
  Stop-VisionClaude

  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  foreach ($dir in @($ServerDir, $SupervisorDir)) {
    Remove-DirWithRetry $dir
  }
  Move-Item $Staged $ServerDir
  New-Item -ItemType Directory -Path $SupervisorDir | Out-Null
  Copy-Item $ServerExe $SupervisorDir
  Copy-Item (Join-Path $ServerDir 'lib\supervisor.js') $SupervisorDir
  $Version = ([IO.File]::ReadAllText((Join-Path $ServerDir 'VERSION'))).Trim()
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
  $projectsRoot = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultRoot } else { $answer.Trim().Trim('"') }
  if (-not (Test-Path $projectsRoot)) { Warn "$projectsRoot doesn't exist yet; create it or edit projectsRoot in $ConfigPath" }
  $cfg = [pscustomobject]@{ claudeBin = $ClaudeBin; projectsRoot = $projectsRoot; bind = @('127.0.0.1', 'lan') }
}
$Port = if ($cfg.PSObject.Properties['port']) { [int]$cfg.port } else { 8790 }
# PS 5.1 known issue: ConvertTo-Json can serialize arrays as {"value":[...],"Count":N} instead of
# a plain JSON array once System.Array picks up an ETS type extension; drop it before converting.
Remove-TypeData System.Array -ErrorAction SilentlyContinue
# UTF-8 without BOM: Node's JSON.parse chokes on a BOM.
[IO.File]::WriteAllText($ConfigPath, ($cfg | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
Ok "Config: $ConfigPath"

# -- Logon task --------------------------------------------------------------
# conhost --headless gives the supervisor (and everything it spawns) a console nobody can see.
$user = "$env:USERDOMAIN\$env:USERNAME"
$supExe = Join-Path $SupervisorDir 'VisionClaudeServer.exe'
$supJs = Join-Path $SupervisorDir 'supervisor.js'
$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless `"$supExe`" `"$supJs`"" -WorkingDirectory $DataDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Ok "Registered logon task '$TaskName'"

# -- Firewall ----------------------------------------------------------------
Remove-FirewallRule
New-NetFirewallRule -DisplayName $FirewallRule -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort $Port -Program $ServerExe -Profile Private | Out-Null
Ok "Firewall: TCP $Port open on Private networks"
$public = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Public' }
if ($public) {
  Warn "Network '$($public[0].Name)' is set to Public, so your Mac can't reach this PC. Switch it to Private in Settings > Network & internet."
}

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
if (-not $healthy) { Die "The server didn't come up within 30 seconds. Check $LogFile" }
Ok 'Server is running'

Write-Host ''
Write-Host 'Pair your Mac: open one of these in a browser on the Mac, then click Yes on this PC:'
foreach ($ip in (Get-LanAddresses)) { Write-Host "   http://${ip}:$Port/pair" }
Write-Host ''
Write-Host "Logs: $LogFile"
if ($ClaudeInstalledNow) {
  Write-Host ''
  Write-Host 'Claude Code was just installed and still needs you to sign in: run `claude` in a new terminal,'
  Write-Host 'or use the Claude account section in the App settings after pairing.'
}
