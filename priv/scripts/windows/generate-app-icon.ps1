#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Generate priv/windows/Launcher/Assets/AppIcon.ico from the macOS 1024x1024 PNG.

.DESCRIPTION
  Uses ImageMagick's `magick` CLI when available (the standard way to produce
  a multi-size .ico). If ImageMagick is not installed, prints installation
  guidance and exits non-zero rather than shipping a broken icon.

  Source: priv/macos/AppIcon-1024.png
  Sizes:  16, 24, 32, 48, 64, 128, 256
  Output: priv/windows/Launcher/Assets/AppIcon.ico
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$Source = Join-Path $RepoRoot 'priv\macos\AppIcon-1024.png'
$Destination = Join-Path $RepoRoot 'priv\windows\Launcher\Assets\AppIcon.ico'

if (-not (Test-Path $Source)) {
    Write-Error "Missing source PNG at $Source. Run mix mac.icon first."
    exit 1
}

if (-not (Get-Command 'magick' -ErrorAction SilentlyContinue)) {
    Write-Error @'
ImageMagick (the `magick` command) is required to generate the ICO file.

Install options:
  * winget install ImageMagick.ImageMagick
  * choco install imagemagick.app
  * https://imagemagick.org/script/download.php#windows

Alternatively, generate AppIcon.ico manually from priv\macos\AppIcon-1024.png
and place it at priv\windows\Launcher\Assets\AppIcon.ico.
'@
    exit 2
}

New-Item -ItemType Directory -Force -Path (Split-Path $Destination) | Out-Null

Write-Host "==> Generating multi-size ICO from $Source" -ForegroundColor Cyan

# ImageMagick reads the PNG once, downsamples to each requested size,
# packs them into a single ICO container. Order matters: Windows picks
# the first close-enough size, so we ship the useful set only.
& magick $Source `
    -define icon:auto-resize=256,128,64,48,32,24,16 `
    $Destination

if ($LASTEXITCODE -ne 0) {
    Write-Error 'magick returned a non-zero exit code.'
    exit $LASTEXITCODE
}

Write-Host "OK -> $Destination" -ForegroundColor Green
