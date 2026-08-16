#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Smoke-test a staged Windows build: launcher CLI verbs, then launch / HTTP 200 /
  shutdown of the OTP release.

.DESCRIPTION
  Runs against the output of build-windows-zip.ps1. Safe to run on a dev box:
  the only persistent state it touches is the HKCU handler registration, which
  it registers and then unregisters again.

  Desktop mode (WinUI 3 window, tray, browser hand-off) is out of scope here —
  it needs an interactive session and is validated by hand.

.PARAMETER StagingRoot
  Staged build directory. Defaults to dist\windows\ElixirTorrentWebUI.

.PARAMETER Port
  Loopback port for the release under test.

.PARAMETER ExpectedVersion
  Version the launcher must report. Defaults to the version in mix.exs.
#>

[CmdletBinding()]
param(
    [string]$StagingRoot,
    [int]$Port = 4321,
    [string]$ExpectedVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')

if (-not $StagingRoot) {
    $StagingRoot = Join-Path $RepoRoot 'dist\windows\ElixirTorrentWebUI'
}

if (-not $ExpectedVersion) {
    $mixFile = Get-Content -Raw (Join-Path $RepoRoot 'mix.exs')
    if ($mixFile -notmatch 'version:\s*"([^"]+)"') {
        throw 'Could not extract version from mix.exs.'
    }
    $ExpectedVersion = $Matches[1]
}

$LauncherExe = Join-Path $StagingRoot 'ElixirTorrentWebUI.Launcher.exe'
$ReleaseBat = Join-Path $StagingRoot 'rel\bin\elixir_torrent_web_ui.bat'
$DataDir = Join-Path ([System.IO.Path]::GetTempPath()) 'ElixirTorrentWebUI-smoke'

foreach ($required in $LauncherExe, $ReleaseBat) {
    if (-not (Test-Path $required)) { throw "Missing $required — run build-windows-zip.ps1 first." }
}

function Invoke-Launcher([string[]]$LauncherArgs) {
    # The launcher is a GUI-subsystem exe: PowerShell's call operator would
    # neither wait for it nor capture stdout. Start-Process with redirection
    # reproduces the pipe-and-wait semantics the release's System.cmd/3 uses.
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $LauncherExe -ArgumentList $LauncherArgs `
            -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $proc.WaitForExit(30000)) {
            $proc.Kill($true)
            throw "Launcher $LauncherArgs did not exit within 30s"
        }
        if ($proc.ExitCode -ne 0) {
            throw "Launcher $LauncherArgs exited $($proc.ExitCode)"
        }
        # Verbs like --register print nothing, and `Get-Content -Raw` on a
        # zero-byte file returns an empty pipeline rather than $null — casting
        # that to [string] yields nothing at all, so calling .Trim() on the
        # result throws. Normalize before touching it.
        $raw = Get-Content -Raw -Path $out -ErrorAction SilentlyContinue
        if (-not $raw) { return '' }
        return $raw.Trim()
    }
    finally {
        Remove-Item -Force -Path $out, $err -ErrorAction SilentlyContinue
    }
}

function Test-PortOpen([int]$TargetPort) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        return $client.ConnectAsync([System.Net.IPAddress]::Loopback, $TargetPort).Wait(1000) `
            -and $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Show-Logs {
    foreach ($name in 'launcher.log', 'server.log') {
        $path = Join-Path $DataDir $name
        Write-Host "===== $path ====="
        if (Test-Path $path) { Get-Content -Tail 200 -Path $path } else { Write-Host '(absent)' }
    }
}

# ------------------------------------------------------------------ CLI verbs

Write-Host '==> Launcher CLI verbs' -ForegroundColor Cyan

$reported = Invoke-Launcher @('--version')
Write-Host "    --version -> $reported"
if (-not $reported.StartsWith($ExpectedVersion)) {
    throw "--version reported '$reported'; expected $ExpectedVersion.x. Keep mix.exs, the .csproj and app.manifest in lockstep."
}

# The release's DefaultHandler parses this exact JSON shape.
$json = Invoke-Launcher @('--check-defaults')
Write-Host "    --check-defaults -> $json"
$status = $json | ConvertFrom-Json
foreach ($field in 'torrent', 'magnet') {
    if ($status.$field -isnot [bool]) {
        throw "--check-defaults JSON is missing a boolean '$field': $json"
    }
}

Write-Host '==> HKCU registration round trip' -ForegroundColor Cyan

Invoke-Launcher @('--register') | Out-Null

# GetValue('') for a key's default value. `Get-ItemProperty -Name '(default)'`
# does not address it and yields an object without that property.
$openCommand = (Get-Item `
        'HKCU:\Software\Classes\ElixirTorrentWebUI.Torrent\shell\open\command').GetValue('')
Write-Host "    .torrent open command -> $openCommand"
if ($openCommand -notmatch '--submit-torrent') {
    throw "Registered .torrent open command looks wrong: $openCommand"
}

# Unregister must drop the ProgIDs and Capabilities but keep the prompt's
# dismissal flag, which lives directly under the app's own HKCU root.
$appRoot = 'HKCU:\Software\ElixirTorrentWebUI'
New-Item -Path $appRoot -Force | Out-Null
New-ItemProperty -Path $appRoot -Name 'DefaultHandlerPromptDismissed' `
    -Value 1 -PropertyType DWord -Force | Out-Null

Invoke-Launcher @('--unregister') | Out-Null

if (Test-Path 'HKCU:\Software\Classes\ElixirTorrentWebUI.Torrent') {
    throw '--unregister left the .torrent ProgID behind'
}
if (Test-Path "$appRoot\Capabilities") {
    throw '--unregister left the Capabilities subtree behind'
}
$dismissed = (Get-ItemProperty -Path $appRoot -Name 'DefaultHandlerPromptDismissed' `
        -ErrorAction SilentlyContinue).DefaultHandlerPromptDismissed
if ($dismissed -ne 1) {
    throw '--unregister wiped DefaultHandlerPromptDismissed; a dismissed nag would come back'
}

Write-Host '    registration round trip OK'

# ------------------------------------------------- Release launch / 200 / stop

Write-Host "==> Release launch on 127.0.0.1:$Port" -ForegroundColor Cyan

# Exactly the environment ServerLifecycle.InjectReleaseEnvironment sets.
$env:PHX_SERVER = 'true'
$env:ELIXIR_TORRENT_DESKTOP = '1'
$env:PORT = "$Port"
$env:ELIXIR_TORRENT_DATA_DIR = $DataDir
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

$started = Start-Process -FilePath 'cmd.exe' `
    -ArgumentList '/C', "`"$ReleaseBat`"", 'start' -NoNewWindow -PassThru
Write-Host "    release pid=$($started.Id)"

try {
    $healthy = $false
    for ($i = 0; $i -lt 120; $i++) {
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -eq 200) { $healthy = $true; break }
        }
        catch {
            # Not up yet.
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $healthy) {
        Show-Logs
        throw "Release never returned HTTP 200 on 127.0.0.1:$Port within 60s"
    }

    Write-Host '    HTTP 200 confirmed'
}
finally {
    Write-Host '==> Graceful stop' -ForegroundColor Cyan
    Start-Process -FilePath 'cmd.exe' `
        -ArgumentList '/C', "`"$ReleaseBat`"", 'stop' -NoNewWindow -Wait

    $closed = $false
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Test-PortOpen $Port)) { $closed = $true; break }
        Start-Sleep -Milliseconds 500
    }

    if (-not $closed) {
        Show-Logs
        throw "Port $Port still accepts connections 10s after 'release stop'"
    }

    Write-Host '    port closed'
}

Write-Host ''
Write-Host 'Smoke test passed.' -ForegroundColor Green
