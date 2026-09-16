<#
.SYNOPSIS
    Install / repair a full-desktop Ubuntu (WSL2) environment reachable over RDP,
    with a live Windows <-> Ubuntu shared folder.

.DESCRIPTION
    1. Enables the WSL2 + Virtual Machine Platform Windows features if missing
       (may require a single reboot - the script tells you and stops cleanly).
    2. Installs the "Ubuntu" WSL distro if it isn't already registered.
    3. Enables systemd inside the distro and installs a full XFCE4 desktop +
       xrdp, so you get a real, complete desktop session (not just individual
       WSLg app windows) - as close to "installed on bare metal" as WSL2 gets.
    4. Creates a "shared" folder next to this script and symlinks it into
       every user's ~/Documents/shared inside Ubuntu, for continuous,
       always-on file sharing between Windows and Ubuntu (no copying/syncing).
    5. Only on a BRAND NEW install: sets the default WSL login to
       user "root" / password "root", prints it, and writes credentials.md.
       If Ubuntu is already installed, existing credentials are left alone.

    Safe to re-run any time - it repairs/refreshes the desktop + xrdp install
    without touching an already-configured user account.

.EXAMPLE
    .\Install-Ubuntu-GUI.ps1
#>

param(
    [string]$DistroName = "Ubuntu",
    [int]$RdpPort = 3390
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"

# --- self-elevate ------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevating to Administrator..." -ForegroundColor Yellow
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-DistroName", "`"$DistroName`"", "-RdpPort", $RdpPort)
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

$RootDir   = $PSScriptRoot
$SharedDir = Join-Path $RootDir "shared"
$CredFile  = Join-Path $RootDir "credentials.md"

function Step($msg) { Write-Host "`n==== $msg ====" -ForegroundColor Cyan }
function Info($msg) { Write-Host $msg -ForegroundColor Gray }
function Ok($msg)   { Write-Host $msg -ForegroundColor Green }
function Warn($msg) { Write-Host $msg -ForegroundColor Yellow }

# Getting a shell script from PowerShell into bash intact takes more care than
# it looks. Two traps, both silent:
#
#   * CRLF. Normalizing the here-string is not enough: piping a string to a
#     native command makes PowerShell append its own CRLF, so the LAST line of
#     the script arrives with a trailing \r. That turned this script's
#     `>> /etc/wsl.conf` into a write to `/etc/wsl.conf<CR>`, and made every
#     script ending in `done` or `fi` die with a syntax error - while
#     PowerShell still reported success.
#
#   * `wsl -- <cmd>` runs <cmd> through the distro's DEFAULT SHELL, which
#     expands $vars and $(...) before the real target ever sees them.
#     `--exec` passes argv straight through instead.
#
# So: write the script out as a real LF-only file and exec bash on it.
function Invoke-WslBash($Script, $Distro = $DistroName, $User = "root") {
    $tmp = Join-Path $env:TEMP ("ubuntu-gui-" + [guid]::NewGuid().ToString("N") + ".sh")
    $body = ($Script -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($tmp, $body + "`n", (New-Object Text.UTF8Encoding($false)))
    try {
        $linuxPath = (& wsl -d $Distro --exec wslpath -a $tmp).Trim()
        & wsl -d $Distro -u $User --exec bash $linuxPath
        if ($LASTEXITCODE -ne 0) {
            throw "a configuration step failed inside $Distro (bash exit code $LASTEXITCODE)"
        }
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    throw "wsl.exe was not found. This Windows build/edition does not support WSL2."
}

# ---------------------------------------------------------------------------
Step "1/6  Checking WSL2 / Virtual Machine Platform Windows features"
# ---------------------------------------------------------------------------
$needsReboot = $false
foreach ($feature in "Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform") {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
    if ($state -ne "Enabled") {
        Info "Enabling $feature ..."
        $r = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
        if ($r.RestartNeeded) { $needsReboot = $true }
    } else {
        Info "$feature already enabled."
    }
}

if ($needsReboot) {
    Warn "`nWindows needs a reboot to finish enabling WSL2."
    Warn "Reboot the machine, then re-run this script to continue where it left off."
    Read-Host "Press Enter to exit"
    exit
}

wsl --update | Out-Null
wsl --set-default-version 2 | Out-Null
Ok "WSL2 is active and set as the default version."

# ---------------------------------------------------------------------------
Step "2/6  Checking for an existing '$DistroName' install"
# ---------------------------------------------------------------------------
$existingRaw = (wsl -l -q) 2>$null
$existing = @()
if ($existingRaw) {
    $existing = $existingRaw | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
$isNewInstall = -not ($existing -contains $DistroName)

if ($isNewInstall) {
    Info "'$DistroName' not found - downloading and registering it (skipping the first-run wizard)..."
    wsl --install -d $DistroName --no-launch
    Start-Sleep -Seconds 5
    wsl --set-default $DistroName | Out-Null
    Ok "$DistroName installed."
} else {
    Ok "$DistroName is already installed - leaving its user/password as-is."
}

# ---------------------------------------------------------------------------
Step "3/6  Configuring wsl.conf (systemd) and default user"
# ---------------------------------------------------------------------------
$confScript = @'
set -e

# Clean up after the CRLF bug described above: it appended the [user] block to
# a file literally named "wsl.conf<CR>" instead of wsl.conf.
rm -f "$(printf '/etc/wsl.conf\r')"

touch /etc/wsl.conf
grep -q "^systemd=true" /etc/wsl.conf || printf "\n[boot]\nsystemd=true\n" >> /etc/wsl.conf
grep -q "^default=" /etc/wsl.conf || printf "\n[user]\ndefault=root\n" >> /etc/wsl.conf
'@
Invoke-WslBash $confScript
wsl --terminate $DistroName | Out-Null
Start-Sleep -Seconds 2
Ok "wsl.conf configured (systemd enabled so xrdp can autostart; default user preserved/set)."

$newPassword = "root"
if ($isNewInstall) {
    Info "Setting the root password for the new install..."
    Invoke-WslBash "echo 'root:$newPassword' | chpasswd"
    Ok "Default login for '$DistroName' -> user: root / password: $newPassword"
}

# ---------------------------------------------------------------------------
Step "4/6  Installing XFCE4 desktop + xrdp inside $DistroName"
# ---------------------------------------------------------------------------
$guiScript = @'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y xfce4 xfce4-goodies xrdp dbus-x11 x11-xserver-utils

# Dedicated port so it never collides with a native Windows RDP listener.
#
# A bare "port=3390" tells xrdp to listen on all interfaces, which it does as
# a single IPv6 (::) socket - and WSL2's localhost relay only forwards IPv4
# bindings, so mstsc against 127.0.0.1 gets ECONNREFUSED forever while xrdp
# looks perfectly healthy from inside the distro. xrdp's tcp://.:PORT URL form
# binds IPv4 127.0.0.1 instead: reachable through the relay, and still never
# exposed off-box. (xrdp has no "address=" key - see the commented examples in
# xrdp.ini - so writing one was a no-op.)
#
# Only the [Globals] port is ours. The per-backend ports must keep their
# packaged defaults ([Xorg]/[Xvnc] port=-1, ...); an unanchored sed in an
# earlier version of this script overwrote them too, which breaks session
# startup after login, so restore any that still hold our port number.
awk -v PORT=__PORT__ '
/^[ \t]*\[/ { section = tolower($0); sub(/[ \t\r]+$/, "", section) }
section == "[globals]" && /^port=/            { print "port=tcp://.:" PORT; next }
section == "[globals]" && /^address=/         { next }
section == "[xorg]"    && $0 == "port=" PORT  { print "port=-1"; next }
section == "[xvnc]"    && $0 == "port=" PORT  { print "port=-1"; next }
section == "[vnc-any]" && $0 == "port=" PORT  { print "port=ask5900"; next }
section == "[neutrinordp-any]" && $0 == "port=" PORT { print "port=ask3389"; next }
{ print }
' /etc/xrdp/xrdp.ini > /etc/xrdp/xrdp.ini.new
mv /etc/xrdp/xrdp.ini.new /etc/xrdp/xrdp.ini

# The default WSL login is root; make sure sesman will actually accept it
# (some xrdp packages ship AllowRootLogin=false, which fails root logins
# with a bare "login failed" and no other clue).
if grep -q '^AllowRootLogin=' /etc/xrdp/sesman.ini; then
    sed -i 's/^AllowRootLogin=.*/AllowRootLogin=true/' /etc/xrdp/sesman.ini
else
    sed -i '0,/^\[Security\]/s//[Security]\nAllowRootLogin=true/' /etc/xrdp/sesman.ini
fi

# The session script. WSLg exports WAYLAND_DISPLAY (and DISPLAY=:0) into every
# process in the distro, so inside an xrdp session XFCE 4.20 picks its Wayland
# backend and draws nothing at all: xfdesktop bails out with "your compositor
# must support the zwlr_layer_shell_v1 protocol" and the client just shows a
# black screen. Pin the session to X11 on the display xrdp handed us.
cat > /etc/skel/.xsession <<'XSESSION'
#!/bin/sh
unset WAYLAND_DISPLAY WAYLAND_SOCKET
export XDG_SESSION_TYPE=x11
export GDK_BACKEND=x11
export QT_QPA_PLATFORM=xcb
exec xfce4-session
XSESSION
chmod +x /etc/skel/.xsession

for home in /root /home/*; do
    if [ -d "$home" ]; then
        install -m 755 -o "$(stat -c %U "$home")" -g "$(stat -c %G "$home")" \
            /etc/skel/.xsession "$home/.xsession"
    fi
done

adduser xrdp ssl-cert || true

# Bring it up now as well as on every boot, then prove it is really listening
# on the loopback address Windows can reach. Swallowing a failure here is what
# leaves the launcher spinning on "Waiting for the desktop session..." later.
systemctl enable xrdp
systemctl restart xrdp
for _ in $(seq 1 20); do
    ss -ltn | grep -q "127.0.0.1:__PORT__" && break
    sleep 1
done
if ! ss -ltn | grep -q "127.0.0.1:__PORT__"; then
    echo "ERROR: xrdp did not start listening on 127.0.0.1:__PORT__" >&2
    systemctl --no-pager -l status xrdp >&2 || true
    exit 1
fi
echo "xrdp is listening on 127.0.0.1:__PORT__"
'@
$guiScript = $guiScript.Replace("__PORT__", $RdpPort)
Invoke-WslBash $guiScript
Ok "XFCE4 desktop + xrdp installed, listening on 127.0.0.1:$RdpPort."

# ---------------------------------------------------------------------------
Step "5/6  Wiring up the shared folder"
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Path $SharedDir -Force | Out-Null
$wslSharedPath = (& wsl -d $DistroName --exec wslpath -a "$SharedDir").Trim()

$shareScript = @'
set -e
for home in /root /home/*; do
    if [ -d "$home" ]; then
        mkdir -p "$home/Documents"
        ln -sfn "__SHARE__" "$home/Documents/shared"
    fi
done

# This step used to fail silently; make a broken link loud instead.
test -d /root/Documents/shared
'@
$shareScript = $shareScript.Replace("__SHARE__", $wslSharedPath)
Invoke-WslBash $shareScript
Ok "Windows folder '$SharedDir' <-> Ubuntu '~/Documents/shared' linked live (no sync process, always up to date)."

# ---------------------------------------------------------------------------
Step "6/6  Credentials"
# ---------------------------------------------------------------------------
wsl --terminate $DistroName | Out-Null

if ($isNewInstall) {
@"
# Ubuntu-GUI credentials

- Distro: $DistroName (WSL2)
- Default login user: **root**
- Password: **$newPassword**
- Desktop: XFCE4 over RDP at 127.0.0.1:$RdpPort (loopback only, not exposed to the LAN)
- Shared folder: ``shared\`` in this folder  <->  ``~/Documents/shared`` inside Ubuntu

Change this password after first login with: ``passwd``

Generated: $(Get-Date -Format s)
"@ | Set-Content -Path $CredFile -Encoding utf8

    Ok "`nNEW INSTALL -> login is root / $newPassword"
    Ok "Credentials saved to $CredFile"
} else {
    Info "Existing install detected - credentials.md left untouched (not overwritten)."
}

Ok "`nSetup complete. Use 'Open Ubuntu GUI.bat' (or Ubuntu-GUI.ps1 -Action Open) to launch the desktop."
