#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build the ElixirTorrentWebUI portable Windows ZIP.

.DESCRIPTION
  Deterministic build pipeline for the signed portable Windows 11 x64 artifact.

  Stages:
    1. `mix deps.get` (respecting ELIXIR_TORRENT_PATH if set).
    2. `mix assets.deploy` (Tailwind + esbuild + phx.digest).
    3. `MIX_ENV=prod mix release --overwrite` to produce the OTP release.
    4. `dotnet publish` for the C# launcher: net10.0-windows / win-x64,
       self-contained. Requires the .NET 10 SDK; Visual Studio is not needed.
    5. Stage everything under dist\windows\ElixirTorrentWebUI\ with the layout
       Launcher.exe consumes at runtime.
    6. Pack into a versioned ZIP + emit SHA-256 checksum.

  Signing (Authenticode) is intentionally out of scope for this script;
  invoke your signing pipeline against
    dist\windows\ElixirTorrentWebUI\ElixirTorrentWebUI.Launcher.exe
  before packing if you sign on the local host.

.PARAMETER Version
  Optional override for the artifact version tag; defaults to the version in
  mix.exs. Only affects the ZIP filename and checksum output, not the assembly
  version already embedded by the .csproj.

.PARAMETER Configuration
  dotnet build configuration (Release / Debug). Defaults to Release.

.PARAMETER SkipDotnetPublish
  Skip the dotnet publish stage — useful when iterating on the Elixir release
  only.

.PARAMETER SkipRelease
  Skip the mix release stage — useful when iterating on the launcher only.
#>

[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [switch]$SkipDotnetPublish,
    [switch]$SkipRelease
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$message) {
    Write-Error $message
    exit 1
}

function Ensure-Tool([string]$name, [string]$hint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Fail "Required tool '$name' was not found on PATH. $hint"
    }
}

# ---------------------------------------------------------------------- Setup

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
Set-Location $RepoRoot

Ensure-Tool 'mix' 'Install Elixir 1.20+ and add it to PATH.'
Ensure-Tool 'dotnet' 'Install the .NET 10 SDK and add it to PATH.'

# The launcher targets net10.0-windows10.0.22621.0. Without this check an older
# SDK fails deep inside `dotnet publish` with an opaque NETSDK1045, so assert
# the requirement up front instead.
$RequiredDotnetMajor = 10
$dotnetSdks = @(& dotnet --list-sdks)
if ($LASTEXITCODE -ne 0) { Fail 'dotnet --list-sdks failed' }

$hasRequiredSdk = $dotnetSdks | Where-Object { $_ -match "^$RequiredDotnetMajor\." }
if (-not $hasRequiredSdk) {
    Fail (@"
The .NET $RequiredDotnetMajor SDK is required to build the launcher
(priv\windows\Launcher targets net10.0-windows10.0.22621.0), but it was not found.

Installed SDKs:
$($dotnetSdks -join "`n")

Install it with:  winget install Microsoft.DotNet.SDK.$RequiredDotnetMajor
"@)
}

if (-not $Version) {
    $mixFile = Get-Content -Raw (Join-Path $RepoRoot 'mix.exs')
    if ($mixFile -match 'version:\s*"([^"]+)"') {
        $Version = $Matches[1]
    }
    else {
        Fail 'Could not extract version from mix.exs.'
    }
}

Write-Host "==> Building ElixirTorrentWebUI $Version for Windows x64" -ForegroundColor Cyan

$DistRoot = Join-Path $RepoRoot 'dist\windows'
$Staging = Join-Path $DistRoot 'ElixirTorrentWebUI'
$ZipPath = Join-Path $DistRoot ("ElixirTorrentWebUI-$Version-windows-x64.zip")
$ChecksumPath = "$ZipPath.sha256"

# Fresh staging every run so we never ship stale bits.
if (Test-Path $DistRoot) {
    Remove-Item -Recurse -Force $DistRoot
}
New-Item -ItemType Directory -Path $Staging | Out-Null

# ------------------------------------------------------------------ Elixir

if (-not $SkipRelease) {
    Write-Host '==> mix deps.get' -ForegroundColor Cyan
    & mix deps.get
    if ($LASTEXITCODE -ne 0) { Fail 'mix deps.get failed' }

    Write-Host '==> mix assets.deploy' -ForegroundColor Cyan
    & mix assets.deploy
    if ($LASTEXITCODE -ne 0) { Fail 'mix assets.deploy failed' }

    Write-Host '==> mix release --overwrite (prod)' -ForegroundColor Cyan
    $env:MIX_ENV = 'prod'
    & mix release --overwrite
    if ($LASTEXITCODE -ne 0) { Fail 'mix release failed' }

    $ReleaseSource = Join-Path $RepoRoot '_build\prod\rel\elixir_torrent_web_ui'
    if (-not (Test-Path $ReleaseSource)) {
        Fail "Expected release output at $ReleaseSource but it was not produced."
    }

    $ReleaseDest = Join-Path $Staging 'rel'
    Copy-Item -Recurse -Force -Path $ReleaseSource -Destination $ReleaseDest
    Write-Host "    staged release at $ReleaseDest"
}
else {
    Write-Host '==> Skipping mix release (SkipRelease)' -ForegroundColor Yellow
    $ReleaseSource = Join-Path $RepoRoot '_build\prod\rel\elixir_torrent_web_ui'
    if (Test-Path $ReleaseSource) {
        Copy-Item -Recurse -Force -Path $ReleaseSource -Destination (Join-Path $Staging 'rel')
    }
}

# ------------------------------------------------------------------ .NET

$LauncherProject = Join-Path $RepoRoot 'priv\windows\Launcher\ElixirTorrentWebUI.Launcher.csproj'

if (-not $SkipDotnetPublish) {
    Write-Host '==> dotnet publish (net10.0-windows / win-x64, self-contained)' -ForegroundColor Cyan
    $publishDir = Join-Path $RepoRoot 'dist\publish\launcher'
    if (Test-Path $publishDir) {
        Remove-Item -Recurse -Force $publishDir
    }

    # Self-contained .NET so the user installs nothing.
    & dotnet publish $LauncherProject `
        --configuration $Configuration `
        --runtime win-x64 `
        --self-contained true `
        -p:PublishSingleFile=false `
        -p:PublishReadyToRun=true `
        --output $publishDir
    if ($LASTEXITCODE -ne 0) { Fail 'dotnet publish failed' }

    $launcherExe = Get-ChildItem -Path $publishDir -Filter 'ElixirTorrentWebUI.Launcher.exe' -File | Select-Object -First 1
    if (-not $launcherExe) {
        Fail "Launcher exe was not produced under $publishDir."
    }

    # Copy the whole publish tree into the staging root: the exe and the
    # .NET runtime files sit next to each other.
    Get-ChildItem -Path $publishDir -Force | ForEach-Object {
        Copy-Item -Recurse -Force -Path $_.FullName -Destination $Staging
    }
}
else {
    Write-Host '==> Skipping dotnet publish (SkipDotnetPublish)' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- Ancillary

# Test fixtures for manual validation: a real torrent that carries both video
# and images, plus its magnet. Staged on every build so a rebuild does not
# silently remove what the manual checklist tells you to open.
# Placed in BOTH dist\windows (next to the ZIP, easy to reach) and inside the
# staged app folder (so they travel with an unpacked copy). The build wipes
# dist\windows first, so anything dropped there by hand does not survive —
# staging them here is what makes them persist across rebuilds.
$FixtureDir = Join-Path $RepoRoot 'priv\windows\testfiles'
if (Test-Path $FixtureDir) {
    Get-ChildItem $FixtureDir -File | ForEach-Object {
        Copy-Item -Force -Path $_.FullName -Destination $Staging
        Copy-Item -Force -Path $_.FullName -Destination $DistRoot
        Write-Host "    staged fixture $($_.Name)"
    }
}

$LauncherReadme = Join-Path $RepoRoot 'priv\windows\README.md'
if (Test-Path $LauncherReadme) {
    Copy-Item -Force -Path $LauncherReadme -Destination (Join-Path $Staging 'README.md')
}

$RootReadme = Join-Path $RepoRoot 'README.md'
if (Test-Path $RootReadme) {
    Copy-Item -Force -Path $RootReadme -Destination (Join-Path $Staging 'ElixirTorrentWebUI-README.md')
}

# ---------------------------------------------------------------- Pack

Write-Host "==> Compressing $Staging -> $ZipPath" -ForegroundColor Cyan
if (Test-Path $ZipPath) {
    Remove-Item -Force $ZipPath
}

Compress-Archive -Path (Join-Path $Staging '*') -DestinationPath $ZipPath -CompressionLevel Optimal

$hash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -Path $ChecksumPath -Value "$hash  $(Split-Path -Leaf $ZipPath)"

Write-Host ''
Write-Host "Artifact:  $ZipPath" -ForegroundColor Green
Write-Host "SHA-256:   $hash" -ForegroundColor Green
Write-Host "Checksum:  $ChecksumPath" -ForegroundColor Green
