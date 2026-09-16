# Auto-WSL2-Ubuntu-GUI-Installer

Turn WSL2's `Ubuntu` distro into a full, real desktop session — reachable
like a locally installed OS, complete with window controls — plus a
continuously live shared folder between Windows and Ubuntu.

Two scripts:

- **`Install-Ubuntu-GUI.ps1`** — one-shot install *and* repair. Enables
  WSL2, installs Ubuntu if missing, installs a full XFCE4 desktop + xrdp
  inside it, wires up the shared folder, and (only on a brand-new install)
  sets default credentials and writes them to `credentials.md`.
- **`Ubuntu-GUI.ps1`** — day-to-day open/close of the desktop session,
  opening as a maximized window ("windowed fullscreen", like Minecraft
  Bedrock's windowed mode — full-screen sized, but still a real window with
  title bar and system controls).

`.bat` launchers are provided for both so nothing requires touching
PowerShell directly.

---

## Contents

| File | Purpose |
|---|---|
| `Install-Ubuntu-GUI.ps1` / `Install-Ubuntu-GUI.bat` | Install / repair everything. Safe to re-run any time. |
| `Ubuntu-GUI.ps1` / `Open Ubuntu GUI.bat` / `Close Ubuntu GUI.bat` | Open or close the desktop session. |
| `shared/` | Windows-side half of the live shared folder. |
| `credentials.md` | Generated on first install only (git-ignored — never committed). |

---

## Requirements

- Windows 10 (build 19041+) or Windows 11, 64-bit.
- Administrator rights (for the install/repair script only — it self-elevates via UAC).
- Internet access for the first run (downloads the Ubuntu WSL rootfs and ~500 MB–1 GB of desktop packages).
- Virtualization enabled in firmware/BIOS (required by WSL2 generally; most machines have this on by default).

---

## Usage guide

### 1. Install / repair

Double-click **`Install-Ubuntu-GUI.bat`** (accept the UAC prompt). It will:

1. Enable the `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform`
   Windows features if they aren't already on.
   - If Windows needs a reboot to finish this, the script says so and exits
     cleanly. Reboot, then run it again — it picks up where it left off.
2. Install the `Ubuntu` WSL distro if it isn't registered yet, skipping the
   interactive first-run wizard (`wsl --install -d Ubuntu --no-launch`).
3. Enable `systemd` inside the distro and install XFCE4 + xrdp so you get an
   actual complete desktop session over RDP, not individual WSLg app windows.
4. Create `shared\` next to the script and symlink it to
   `~/Documents/shared` for every Linux user.
5. **Only if Ubuntu was just installed fresh**: set the default login to
   `root` / `root`, print it, and save it to `credentials.md`. An existing
   install's user/password is left completely untouched.

Re-run this script any time — it's idempotent. If the desktop/xrdp install
gets broken (bad update, corrupted config, etc.), running it again repairs
it without resetting your account.

### 2. Open the desktop

Double-click **`Open Ubuntu GUI.bat`**. It boots the WSL2 instance, waits
for the desktop session to come up, then opens it as a maximized window
sized to your monitor. Log in with the credentials from `credentials.md`
(or your own, if Ubuntu was already installed before you ran this).

### 3. Close the desktop

Double-click **`Close Ubuntu GUI.bat`**. It closes the RDP window and
terminates the WSL2 Ubuntu instance to free CPU/RAM. Any other WSL distros
you have installed are untouched.

### 4. Shared folder

`shared\` (next to the scripts) and `~/Documents/shared` (inside Ubuntu) are
the same data at all times while the WSL instance is running — no syncing,
no copying, just a live symlink through WSL2's DrvFs mount. Drop a file in
either side and it's immediately visible on the other.

All other Windows drives are also always reachable inside Ubuntu under
`/mnt/c`, `/mnt/d`, etc., independently of this shared folder.

### 5. Change the default password

Open a terminal in the desktop session and run:

```bash
passwd
```

---

## Technical explanation

### Why xrdp + XFCE4 instead of WSLg alone

WSLg (Microsoft's built-in WSL GUI support) renders individual Linux GUI
apps as separate Windows windows via a Wayland/X11 compositor. That's great
for running one app, but it isn't a full desktop session — no taskbar, no
window manager of its own, no persistent desktop state across apps.

This project instead installs a genuine desktop environment (XFCE4) and an
RDP server (`xrdp`) *inside* the WSL2 Linux instance, then connects to it
with Windows' built-in Remote Desktop client (`mstsc.exe`). The result
behaves like a real, separate machine with its own desktop, panel, window
manager, and session state — as close to "installed on bare metal" as WSL2
gets, while still running entirely inside the lightweight WSL2 VM.

### Networking and security

- xrdp is configured to listen on **`127.0.0.1:3390`** only
  (`/etc/xrdp/xrdp.ini`), not `0.0.0.0`. It is never reachable from the LAN
  or WAN — only from the Windows host itself.
- Port `3390` (not the default `3389`) avoids any collision with Windows'
  own Remote Desktop server if you have that enabled separately.
- WSL2's *localhost forwarding* (on by default on modern Windows) is what
  lets `127.0.0.1:3390` on the Windows side reach the service running
  inside the Linux VM.
- `AllowRootLogin=true` is explicitly set in `/etc/xrdp/sesman.ini`, since
  the default WSL login is `root` and some xrdp builds ship that disabled
  by default (which would otherwise reject the login with a bare "login
  failed" and no further explanation).

### systemd and autostart

WSL2 distros don't run an init system by default. The installer turns on
`systemd=true` in `/etc/wsl.conf`, which makes the WSL2 Ubuntu instance boot
a real `systemd` PID 1 — the same as physical/VM Ubuntu — so `xrdp.service`
(enabled via `systemctl enable xrdp`) starts automatically the moment the
instance boots, with no manual step needed each session.

### Default user

A fresh `wsl --install -d Ubuntu --no-launch` skips the interactive
first-run wizard, which is also the step that normally creates a personal
non-root user. With no such user created, WSL's default login falls back to
`root` already — the installer just sets `root`'s password and writes an
explicit `[user] default=root` into `/etc/wsl.conf` for clarity. Nothing
about an already-installed distro's existing user is touched.

### Windowed fullscreen, not exclusive fullscreen

`Ubuntu-GUI.ps1` deliberately avoids `mstsc /f` (true exclusive fullscreen,
which hides the title bar entirely behind an auto-hiding connection bar).
Instead it:

1. Calls `SetProcessDPIAware()` before reading the monitor's resolution, so
   `Screen.Bounds` reports true physical pixels instead of a DPI-scaled
   value (otherwise a 150%-scaled 1080p display would report ~1280×720).
2. Generates a `.rdp` file with that physical resolution plus
   `dynamic resolution:i:1` (xrdp resizes the remote XFCE session live to
   match the actual client window size via the RDP display-control channel)
   and `smart sizing:i:1` as a fallback if that channel isn't negotiated.
3. Launches `mstsc.exe` normally, then finds its window handle and calls
   `ShowWindowAsync(hwnd, SW_MAXIMIZE)` via `user32.dll` — maximizing it
   like any other window.

The result: a window that fills the screen but keeps its title bar, system
menu, and minimize/restore/close controls — the same feel as Minecraft
Bedrock Edition's windowed-fullscreen mode.

### Idempotency / repair semantics

Every step in `Install-Ubuntu-GUI.ps1` is written to be safe to re-run:

- Feature enablement checks current state before touching it.
- Distro install is skipped if `Ubuntu` is already registered
  (`wsl -l -q`).
- `wsl.conf`, `xrdp.ini`, and `sesman.ini` edits use `grep`-guarded
  `sed`/`printf`, so they don't duplicate settings on a second run.
- The `root`/`root` credential reset **only** happens on a first-time
  install (`$isNewInstall`); an existing distro's account is never modified.

This means the same script doubles as a repair tool: if xrdp stops working
after a package update, just run `Install-Ubuntu-GUI.ps1` again.

### Getting bash scripts into WSL intact

The install script builds several small bash scripts as PowerShell
here-strings. Handing those to WSL correctly takes more care than it looks,
because both failure modes are silent:

- **Trailing `CR`.** Normalizing a here-string to `\n` is not enough: piping a
  string to a native command makes PowerShell append its *own* `CRLF`, so the
  last line of the script arrives in bash with a trailing `\r`. That is enough
  to turn `>> /etc/wsl.conf` into a write to a file literally named
  `wsl.conf<CR>`, and to make any script ending in `done` or `fi` die with a
  syntax error — while PowerShell still reports success.
- **`wsl -- <cmd>` uses the default shell.** Everything after `--` is run
  *through the distro's login shell*, which expands `$vars` and `$(...)`
  before the real target ever sees them. `wsl --exec <cmd>` passes argv
  through untouched.

So `Invoke-WslBash` writes each script out as a real LF-only file and runs
`wsl --exec bash <file>` on it, and every other in-distro call in both scripts
uses `--exec`. `Invoke-WslBash` also throws if bash exits non-zero, so a failed
configuration step can no longer be reported as a success.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Install script says a reboot is needed | WSL2/VMP features were just enabled and need one restart. Reboot, then re-run the script. |
| `Open Ubuntu GUI.bat` times out waiting for xrdp | Check where xrdp is listening (`ss -ltn` as root inside Ubuntu). It must be `127.0.0.1:3390`, **not** `*:3390` — WSL only forwards IPv4 bindings to the Windows `localhost` address, so an all-interfaces (IPv6 `::`) listener is invisible from Windows. `Install-Ubuntu-GUI.ps1` sets `port=tcp://.:3390` to force the IPv4 loopback bind; re-run it to repair. The launcher prints this diagnostic itself on timeout. |
| RDP connects, then "cannot connect to the remote computer" | The WSL instance shut down under the session. WSL stops a distro ~15s after the last `wsl.exe` client exits (systemd inside does not prevent this), so `Ubuntu-GUI.ps1 -Action Open` holds a hidden `wsl --exec sleep infinity` session open for the lifetime of the desktop. `-Action Close` ends it. |
| Desktop is a black screen after login | XFCE picked its Wayland backend: WSLg exports `WAYLAND_DISPLAY` into every process in the distro, and `xfdesktop` then refuses to draw ("your compositor must support the zwlr_layer_shell_v1 protocol"). `~/.xsession` must unset `WAYLAND_DISPLAY` and pin `GDK_BACKEND=x11` before exec'ing `xfce4-session`; re-run `Install-Ubuntu-GUI.ps1` to rewrite it. |
| Login rejected in the RDP window | Check `credentials.md`; if you changed the password with `passwd`, use the new one. |
| Session window has scrollbars / doesn't fill the window | Update `xrdp` (`apt-get upgrade xrdp` as root inside Ubuntu) — older builds may not support the dynamic-resolution channel; `smart sizing` should still cover this case. |
| Shared folder empty on one side | Make sure the WSL instance is running (`Open Ubuntu GUI.bat`); the link is live only while WSL2 is up. |

---

## Suggested extras (not included, easy to add)

- A scheduled task to launch `Open Ubuntu GUI.bat` automatically at Windows logon.
- `wsl --export` snapshots before risky in-Ubuntu changes.
- A second, throwaway WSL distro (`wsl --import`) for experiments.
- A periodic `apt upgrade` scheduled task.

---

## License

No license file is included; all rights reserved by default until you add one.
