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

# wsl/bash reads stdin literally, so a PowerShell here-string's CRLF line
# endings show up inside bash as trailing \r on every line (breaking `set -e`
# and, critically, corrupting piped secrets like the chpasswd password).
# Normalize to LF before ever piping a script into `bash -s`.
function Invoke-WslBash($Script, $Distro = $DistroName, $User = "root") {
    ($Script -replace "`r`n", "`n") | wsl -d $Distro -u $User -- bash -s
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
    wsl -d $DistroName -u root -- bash -c "echo 'root:$newPassword' | chpasswd"
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

# Dedicated port so it never collides with a native Windows RDP listener,
# and bind to loopback only so it is never reachable off-box.
sed -i "s/^port=.*/port=__PORT__/" /etc/xrdp/xrdp.ini
sed -i '/^#\?address=/d' /etc/xrdp/xrdp.ini
sed -i '0,/^\[globals\]/s//[globals]\naddress=127.0.0.1/' /etc/xrdp/xrdp.ini

# The default WSL login is root; make sure sesman will actually accept it
# (some xrdp packages ship AllowRootLogin=false, which fails root logins
# with a bare "login failed" and no other clue).
if grep -q '^AllowRootLogin=' /etc/xrdp/sesman.ini; then
    sed -i 's/^AllowRootLogin=.*/AllowRootLogin=true/' /etc/xrdp/sesman.ini
else
    sed -i '0,/^\[Security\]/s//[Security]\nAllowRootLogin=true/' /etc/xrdp/sesman.ini
fi

echo "xfce4-session" > /etc/skel/.xsession
for home in /root /home/*; do
    if [ -d "$home" ]; then echo "xfce4-session" > "$home/.xsession"; fi
done

adduser xrdp ssl-cert || true
systemctl enable xrdp >/dev/null 2>&1 || true
'@
$guiScript = $guiScript.Replace("__PORT__", $RdpPort)
Invoke-WslBash $guiScript
Ok "XFCE4 desktop + xrdp installed, listening on 127.0.0.1:$RdpPort."

# ---------------------------------------------------------------------------
Step "5/6  Wiring up the shared folder"
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Path $SharedDir -Force | Out-Null
$wslSharedPath = (wsl -d $DistroName -- wslpath -a "$SharedDir").Trim()

$shareScript = @'
set -e
for home in /root /home/*; do
    if [ -d "$home" ]; then
        mkdir -p "$home/Documents"
        ln -sfn "__SHARE__" "$home/Documents/shared"
    fi
done
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
