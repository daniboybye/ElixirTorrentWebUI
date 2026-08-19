# ElixirTorrent Web — Windows launcher

`ElixirTorrentWebUI.Launcher.exe` wraps the Elixir OTP release into a Windows 11
x64 desktop experience.

## Stack

- **.NET 10**, self-contained: nothing has to be installed on the machine.
- **Plain Win32** throughout. The launcher has no XAML runtime and no window of
  its own — its entire UI is a `Shell_NotifyIcon` tray entry, a `MessageBoxW`
  for failures, and the COM `IFileOpenDialog` folder picker. A `MessageLoop`
  provides the message pump and a synchronization context.
- **Windows Job Object**, so the OTP release always dies with the launcher, even
  on an ungraceful crash.

## What the launcher does

- Enforces one running instance per user (named mutex + named-pipe forwarding).
- Selects a loopback port and starts the OTP release under the Job Object.
- Sets `PHX_SERVER=true`, `ELIXIR_TORRENT_DESKTOP=1`, `PORT=<chosen>`,
  `ELIXIR_TORRENT_DATA_DIR=%LOCALAPPDATA%\ElixirTorrentWebUI`, and
  `ELIXIR_TORRENT_LAUNCHER=<own path>` for the release.
- Redirects release stdout/stderr into a bounded, rotated `server.log`.
- Opens the browser once the release passes an HTTP health check.
- Forwards later `magnet:` and `.torrent` invocations to the running instance
  over a named pipe. It does not reopen the browser for those: the page is a
  LiveView and picks them up on its own.
- Exposes the shell helpers the release calls over `System.cmd/3`:
  `--pick-folder`, `--open-file`, `--reveal`.
- Registers per-user (`HKCU`) `magnet:` and `.torrent` handlers on `--register`
  and removes them on `--unregister`. No administrator rights are ever
  requested, and neither verb touches a registration that is not ours.

## Distribution

A portable ZIP — extract and run. There is no installer, no uninstaller and no
Add/Remove Programs entry; removing the app means deleting the folder, after
running `--unregister` if the file associations were ever registered. Mutable
state lives outside the ZIP, under `%LOCALAPPDATA%\ElixirTorrentWebUI`:

- `server.log` and `launcher.log` (rotated, 512 KiB × 3 files each)
- `inbox\` — `.torrent` files staged when forwarded through the launcher

Both directories are created lazily on first launch.

## Building

Requires Elixir 1.20+, Node/esbuild (via mix aliases), and the **.NET 10 SDK**.
Visual Studio is not needed.

```powershell
$env:ELIXIR_TORRENT_PATH = 'C:\path\to\ElixirTorrent'   # optional, dev only
pwsh .\priv\scripts\windows\build-windows-zip.ps1
```

Outputs land under `dist\windows\`:

- `ElixirTorrentWebUI-<version>-windows-x64.zip`
- `ElixirTorrentWebUI-<version>-windows-x64.zip.sha256`

### Signing

The signature has to be inside the ZIP, so `build-windows-zip.ps1` signs the
launcher itself, between staging and packing — the same place the macOS build
runs `codesign` before assembling the DMG. Authenticode has no ad-hoc mode, so
by default nothing is signed at all:

```powershell
# Unsigned, as before.
pwsh .\priv\scripts\windows\build-windows-zip.ps1

# Real signature from a throwaway certificate created and destroyed by the run.
# Proves the signing path works; SmartScreen still warns, because nothing
# trusts the certificate.
pwsh .\priv\scripts\windows\build-windows-zip.ps1 -SelfSignedSignature

# A certificate you actually hold, by thumbprint. Also read from
# $env:WINDOWS_SIGN_THUMBPRINT.
pwsh .\priv\scripts\windows\build-windows-zip.ps1 -SignThumbprint <40 hex chars>
```

Only the two binaries we build are signed — the rest of the staged tree is the
.NET runtime, already signed by Microsoft. The private key is never exported: it
is used where it lives, which since June 2023 is the only form a publicly-trusted
code-signing key is allowed to exist in. A cloud/HSM signing service drives
signtool through `/dlib` rather than a store lookup and is not wired up.

Signatures are verified after they are applied: a signature has to be present and
belong to the certificate that was asked for, and a configured (non-throwaway)
certificate additionally has to chain to a trusted root or the build fails.

To verify a staged build — CLI verbs, the HKCU registration round trip, then
launch / HTTP 200 / graceful shutdown of the release:

```powershell
pwsh .\priv\scripts\windows\smoke-test.ps1
```

## CLI reference

```
ElixirTorrentWebUI.Launcher.exe                     Launch desktop mode.
ElixirTorrentWebUI.Launcher.exe --submit-magnet URI Forward a magnet link.
ElixirTorrentWebUI.Launcher.exe --submit-torrent P  Forward a .torrent file.
ElixirTorrentWebUI.Launcher.exe --pick-folder       Show folder picker (stdout).
ElixirTorrentWebUI.Launcher.exe --open-file PATH    ShellExecute the file.
ElixirTorrentWebUI.Launcher.exe --reveal PATH       Explorer /select on a file.
ElixirTorrentWebUI.Launcher.exe --register          HKCU handler registration.
ElixirTorrentWebUI.Launcher.exe --unregister        Remove HKCU registration.
ElixirTorrentWebUI.Launcher.exe --check-defaults    Print {"torrent":…,"magnet":…}.
ElixirTorrentWebUI.Launcher.exe --register-defaults Register, then open Settings.
ElixirTorrentWebUI.Launcher.exe --await-default-status
                                                    Block ≤15s until default.
ElixirTorrentWebUI.Launcher.exe --version           Print launcher version.
```

The launcher is a GUI-subsystem executable, so a shell neither waits for it nor
captures its stdout by default. The verbs that print something are meant to be
invoked with redirected pipes, which is what the release's `System.cmd/3` calls
do. From PowerShell, use `Start-Process -RedirectStandardOutput … -PassThru`
plus `WaitForExit`.

Exit codes: `0` success, `1` bad or missing argument, `2` operation failed,
`3` unhandled error, `4` release would not start, `5` release never became
HTTP-ready.
