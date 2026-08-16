# ElixirTorrent Web — Windows launcher

This directory holds the native launcher (`ElixirTorrentWebUI.Launcher.exe`)
that wraps the Elixir OTP release into a Windows 11 x64 desktop experience.

## Stack

- **.NET 10** (LTS) targeting `net10.0-windows10.0.22621.0`
- **WinUI 3** (Windows App SDK 1.7+) for the app model, dispatcher and window
- **Unpackaged, self-contained deployment** — the Windows App SDK Runtime is
  bundled inside the app; the user does not need to install anything
- **P/Invoke** for tray (`Shell_NotifyIcon`), folder picker (`IFileOpenDialog`),
  and modal error surfacing (`MessageBoxW`) — WinUI 3 has no first-party
  equivalents for those primitives
- **Windows Job Object** so the OTP release always dies with the launcher, even
  on ungraceful crashes

## What the launcher does

- Enforces one running instance per user (named mutex + named-pipe forwarding).
- Selects a loopback port and starts the OTP release under a Windows Job Object.
- Sets `PHX_SERVER=true`, `ELIXIR_TORRENT_DESKTOP=1`, `PORT=<chosen>`,
  `ELIXIR_TORRENT_DATA_DIR=%LOCALAPPDATA%\ElixirTorrentWebUI`, and
  `ELIXIR_TORRENT_LAUNCHER=<own path>` for the release process.
- Redirects release stdout/stderr into a bounded, rotated `server.log`.
- Opens the browser at `http://127.0.0.1:<port>/` once the release passes an
  HTTP health check.
- Forwards subsequent `magnet:` and `.torrent` invocations from any launcher
  process to the primary instance over a named pipe.
- Exposes shell helpers used by the Elixir engine adapter over `System.cmd`:
  `--pick-folder`, `--open-file`, `--reveal`.
- Registers per-user (`HKCU`) `magnet:` and `.torrent` handlers on
  `--register`; removes them on `--unregister`. No administrator rights are
  ever requested.

## Distribution layout

The portable ZIP built by `priv\scripts\windows\build-windows-zip.ps1` looks
like:

```
ElixirTorrentWebUI\
├── ElixirTorrentWebUI.Launcher.exe          # signed WinExe entry point
├── ElixirTorrentWebUI.Launcher.dll          # managed code
├── Microsoft.WindowsAppRuntime.Bootstrap.dll
├── Microsoft.ui.xaml.dll                    # WinUI 3 native
├── … (Windows App SDK + .NET runtime DLLs)
├── rel\                                     # mix release (ERTS + BEAM + code)
│   ├── bin\elixir_torrent_web_ui.bat
│   ├── lib\
│   ├── releases\
│   └── …
└── README.md
```

The number of DLLs next to the launcher exe is expected: WinUI 3 cannot be
single-file-published and its native components must sit beside the entry
point.

Mutable state lives outside the ZIP, always under
`%LOCALAPPDATA%\ElixirTorrentWebUI`:

- `server.log` (rotated, capped at 512 KiB per file × 3 files)
- `launcher.log` (rotated, same policy)
- `inbox\` (staged `.torrent` files forwarded through the launcher)

Both directories are created lazily on first launch.

## Building

Requires Elixir 1.20+, Node/esbuild (via mix aliases), and the **.NET 10 SDK**.
Visual Studio is *not* required.

Keep `Microsoft.WindowsAppSDK` on 2.x. The 1.7 line routed the build through
MSIX/PRI MSBuild targets that load `Microsoft.Build.AppxPackage.dll` and
`Microsoft.Build.Packaging.Pri.Tasks.dll` from a Visual Studio MSBuild tree, so
on an SDK-only machine `dotnet publish` produced the launcher `.dll` and then
died with MSB4062 — with no way out, since those are .NET Framework task
assemblies that the .NET-Core MSBuild behind `dotnet` cannot load in-process.
2.x drops that dependency and publishes from the SDK alone.

```powershell
$env:ELIXIR_TORRENT_PATH = 'C:\path\to\ElixirTorrent'   # optional, dev only
pwsh .\priv\scripts\windows\build-windows-zip.ps1
```

Outputs land under `dist\windows\`:

- `ElixirTorrentWebUI-<version>-windows-x64.zip`
- `ElixirTorrentWebUI-<version>-windows-x64.zip.sha256`

Sign `dist\windows\ElixirTorrentWebUI\ElixirTorrentWebUI.Launcher.exe` with
your Authenticode pipeline before packaging the ZIP if you sign locally.

To verify a staged build — launcher CLI verbs, HKCU registration round trip,
then launch / HTTP 200 / graceful shutdown of the release:

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

The launcher is a GUI-subsystem executable, so a shell will not wait for it and
will not capture its stdout by default. The verbs that print something are meant
to be invoked with redirected pipes — which is what the release's own
`System.cmd/3` calls do. From PowerShell, use
`Start-Process -RedirectStandardOutput … -PassThru` plus `WaitForExit`.

Exit codes: `0` success, `1` bad or missing argument, `2` operation failed,
`3` unhandled error, `4` release would not start, `5` release never became
HTTP-ready.
