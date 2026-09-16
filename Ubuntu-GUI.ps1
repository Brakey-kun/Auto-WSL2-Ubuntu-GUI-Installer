<#
.SYNOPSIS
    Open or close the Ubuntu-GUI desktop session (WSL2 + XFCE4 + xrdp).

.DESCRIPTION
    Open:  boots the WSL2 Ubuntu instance, waits for xrdp to come up on
           127.0.0.1, then launches an RDP session sized to fill the primary
           monitor and maximizes it - a "windowed fullscreen" window with a
           normal title bar / system controls (like Minecraft Bedrock's
           windowed-fullscreen mode), not an exclusive borderless fullscreen.

    Close: closes the RDP window and terminates the WSL2 Ubuntu instance to
           free its CPU/RAM, without touching any other installed distro.

.EXAMPLE
    .\Ubuntu-GUI.ps1 -Action Open
    .\Ubuntu-GUI.ps1 -Action Close
#>

param(
    [ValidateSet("Open", "Close")]
    [string]$Action = "Open",
    [string]$DistroName = "Ubuntu",
    [int]$RdpPort = 3390
)

$ErrorActionPreference = "Stop"
$StateFile = Join-Path $env:TEMP "ubuntu-gui.pid"
$RdpFile   = Join-Path $env:TEMP "ubuntu-gui.rdp"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace UbuntuGui -Name Win32 -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
"@

# Query screen size in real physical pixels, not the virtualized/scaled
# bounds a DPI-unaware process would otherwise receive.
[void][UbuntuGui.Win32]::SetProcessDPIAware()

function Test-Port($portNum, $timeoutSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $iar = $client.BeginConnect("127.0.0.1", $portNum, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(800) -and $client.Connected) { return $true }
        } catch {
        } finally {
            $client.Close()
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

if ($Action -eq "Open") {
    Write-Host "Starting $DistroName ..." -ForegroundColor Cyan
    # WSL shuts a distro down roughly 15 seconds after the last wsl.exe client
    # exits - systemd running inside does not keep it alive - so a fire-and-
    # forget boot command would take xrdp down again moments later, right as
    # the RDP client tries to connect. Hold one hidden, long-lived session open
    # for the lifetime of the desktop; -Action Close ends it.
    $keepAlive = Start-Process -FilePath wsl `
        -ArgumentList "-d", $DistroName, "-u", "root", "--exec", "sleep", "infinity" `
        -WindowStyle Hidden -PassThru

    # systemd starts xrdp on boot, but ask for it explicitly as well: that is
    # idempotent, and it recovers a stopped or crashed service instead of
    # silently waiting out the timeout below. Retry, because on a cold boot
    # systemctl can get here before systemd is able to answer it.
    #
    # Note "--exec": plain `wsl -- <cmd>` runs <cmd> through the distro's
    # default shell, which expands $vars and $(...) first; --exec passes argv
    # through untouched.
    # The try/catch is load-bearing: $ErrorActionPreference = "Stop" turns a
    # native command's stderr into a terminating error once its output is
    # piped, so an early "Failed to start" from a not-yet-ready systemd would
    # abort the launcher outright instead of being retried.
    for ($i = 0; $i -lt 20; $i++) {
        $started = $false
        try {
            & wsl -d $DistroName -u root --exec systemctl start xrdp 2>&1 | Out-Null
            $started = ($LASTEXITCODE -eq 0)
        } catch { }
        if ($started) { break }
        Start-Sleep -Seconds 1
    }

    Write-Host "Waiting for the desktop session (xrdp) to come up..." -ForegroundColor Cyan
    if (-not (Test-Port -portNum $RdpPort -timeoutSec 60)) {
        Write-Host "xrdp never came up on 127.0.0.1:$RdpPort." -ForegroundColor Red
        Write-Host "`nDiagnostics from inside ${DistroName}:" -ForegroundColor Yellow
        & wsl -d $DistroName -u root --exec systemctl --no-pager --lines 10 status xrdp
        & wsl -d $DistroName -u root --exec grep -n '^port=' /etc/xrdp/xrdp.ini
        & wsl -d $DistroName -u root --exec ss -ltn
        Write-Host "`nIf xrdp is listening on *:$RdpPort rather than 127.0.0.1:$RdpPort, that is the" -ForegroundColor Yellow
        Write-Host "problem: WSL only forwards IPv4 bindings to the Windows localhost address." -ForegroundColor Yellow
        Write-Host "Re-run Install-Ubuntu-GUI.ps1 to (re)install/repair the GUI." -ForegroundColor Red
        exit 1
    }

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    @"
full address:s:127.0.0.1:$RdpPort
username:s:root
screen mode id:i:1
desktopwidth:i:$($screen.Width)
desktopheight:i:$($screen.Height)
session bpp:i:32
compression:i:1
prompt for credentials:i:1
authentication level:i:0
enablecredsspsupport:i:0
redirectclipboard:i:1
redirectprinters:i:0
audiomode:i:0
dynamic resolution:i:1
smart sizing:i:1
"@ | Set-Content -Path $RdpFile -Encoding ASCII

    $proc = Start-Process -FilePath mstsc -ArgumentList "`"$RdpFile`"" -PassThru
    Set-Content -Path $StateFile -Value @($proc.Id, $keepAlive.Id)

    # "Windowed fullscreen" feel: a normal, maximized window with a title bar
    # and system controls, rather than mstsc's exclusive /f fullscreen mode.
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 30 -and $hwnd -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 500
        $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $hwnd = $p.MainWindowHandle }
    }
    if ($hwnd -ne [IntPtr]::Zero) {
        [UbuntuGui.Win32]::ShowWindowAsync($hwnd, 3) | Out-Null   # SW_MAXIMIZE
        [UbuntuGui.Win32]::SetForegroundWindow($hwnd) | Out-Null
    }
    Write-Host "Ubuntu desktop launched." -ForegroundColor Green
}
elseif ($Action -eq "Close") {
    if (Test-Path $StateFile) {
        Get-Content $StateFile |
            Where-Object { $_ -match '^\s*\d+\s*$' } |
            ForEach-Object { Stop-Process -Id ([int]$_.Trim()) -Force -ErrorAction SilentlyContinue }
        Remove-Item $StateFile -ErrorAction SilentlyContinue
    } else {
        Get-Process mstsc -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -match "127\.0\.0\.1" } |
            Stop-Process -ErrorAction SilentlyContinue
    }

    Write-Host "Shutting down the $DistroName WSL instance..." -ForegroundColor Cyan
    wsl --terminate $DistroName | Out-Null
    Write-Host "Ubuntu-GUI session closed." -ForegroundColor Green
}
