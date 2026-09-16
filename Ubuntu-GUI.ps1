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
    Start-Process -FilePath wsl -ArgumentList "-d", $DistroName, "--", "true" -WindowStyle Hidden -Wait

    Write-Host "Waiting for the desktop session (xrdp) to come up..." -ForegroundColor Cyan
    if (-not (Test-Port -portNum $RdpPort -timeoutSec 60)) {
        Write-Host "xrdp never came up on 127.0.0.1:$RdpPort." -ForegroundColor Red
        Write-Host "Run Install-Ubuntu-GUI.ps1 to (re)install/repair the GUI." -ForegroundColor Red
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
    Set-Content -Path $StateFile -Value $proc.Id

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
        $pidVal = Get-Content $StateFile | Select-Object -First 1
        Stop-Process -Id $pidVal -ErrorAction SilentlyContinue
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
