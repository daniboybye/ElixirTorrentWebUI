#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build the ElixirTorrentWebUI portable Windows ZIP.

.DESCRIPTION
  Build pipeline for the portable Windows 11 x64 artifact.

  The assemblies are deterministic (<Deterministic> in the .csproj), but the ZIP
  is not byte-reproducible: Compress-Archive records file timestamps, so two runs
  over identical sources yield different SHA-256 values. The checksum identifies
  one artifact; it does not attest to the source it came from.

  Stages:
    1. `mix deps.get` (respecting ELIXIR_TORRENT_PATH if set).
    2. `mix assets.deploy` (Tailwind + esbuild + phx.digest).
    3. `MIX_ENV=prod mix release --overwrite` to produce the OTP release.
    4. `dotnet publish` for the C# launcher: net10.0-windows / win-x64,
       self-contained. Requires the .NET 10 SDK; Visual Studio is not needed.
    5. Stage everything under dist\windows\ElixirTorrentWebUI\ with the layout
       Launcher.exe consumes at runtime.
    6. Sign the launcher (see SignThumbprint / SelfSignedSignature).
    7. Pack into a versioned ZIP + emit SHA-256 checksum.

  Authenticode signing happens here, between staging and packing, because the
  signature has to be inside the ZIP. Mirrors the macOS build, which signs the
  .app before it goes into the DMG.

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

.PARAMETER SignThumbprint
  Thumbprint of a code-signing certificate in the current user's store to sign
  the launcher with. Defaults to $env:WINDOWS_SIGN_THUMBPRINT. The private key
  never leaves the store or token, which since June 2023 is the only form a
  publicly-trusted code-signing key is allowed to exist in — so this is the
  parameter a real certificate plugs into, on a machine that holds it.

.PARAMETER SelfSignedSignature
  Sign with a throwaway self-signed certificate created and destroyed by this
  run. Exercises the whole signing path without a certificate and without
  touching any trust store — the signature is real but trusted by nobody, so
  SmartScreen still warns. Ignored when a thumbprint is available.

.PARAMETER TimestampUrl
  RFC 3161 timestamp authority. Empty string skips timestamping.
#>

[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [switch]$SkipDotnetPublish,
    [switch]$SkipRelease,
    [string]$SignThumbprint,
    [switch]$SelfSignedSignature,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
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

# Fresh staging every run so we never ship stale bits. A previous smoke test
# leaves epmd.exe running out of the staged tree, and Windows will not delete a
# running image — the wipe then fails with an opaque access-denied on a path
# nobody would connect to the last test run. Stop those first.
if (Test-Path $DistRoot) {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($DistRoot, [System.StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object {
            Write-Host "    stopping $($_.ProcessName) (pid $($_.Id)) — it holds a file under dist\windows"
            $_.Kill($true)
            $_.WaitForExit(5000) | Out-Null
        }

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
    $ReleaseSource = Join-Path $RepoRoot '_build\prod\rel\elixir_torrent_web_ui'

    if (Test-Path $ReleaseSource) {
        Remove-Item -Recurse -Force $ReleaseSource
    }

    & mix release --overwrite
    if ($LASTEXITCODE -ne 0) { Fail 'mix release failed' }
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
    if (-not (Test-Path $ReleaseSource)) {
        Fail "SkipRelease was given but no previous release exists at $ReleaseSource. Run without -SkipRelease first."
    }

    Copy-Item -Recurse -Force -Path $ReleaseSource -Destination (Join-Path $Staging 'rel')
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

# Manual-test fixtures land next to the ZIP, never inside it. They live outside
# priv/ on purpose: mix release packages priv/ wholesale, so a fixture left
# there shipped inside the release itself — copying or not copying it here made
# no difference at all.
$FixtureDir = Join-Path $RepoRoot 'testfiles'
if (Test-Path $FixtureDir) {
    Get-ChildItem $FixtureDir -File | ForEach-Object {
        Copy-Item -Force -Path $_.FullName -Destination $DistRoot
        Write-Host "    copied local fixture $($_.Name) (not in the ZIP)"
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

# ---------------------------------------------------------------- Signing

# Authenticode has no ad-hoc mode, so with nothing configured the launcher ships
# unsigned rather than carrying a signature nobody asked for. A cloud/HSM signing
# service (Azure Trusted Signing and friends) drives signtool through /dlib
# instead of a store lookup and would need its own branch here.

$ThrowawayCommonName = 'ElixirTorrentWebUI build (self-signed, untrusted)'
$ThrowawaySubject = "CN=$ThrowawayCommonName"
$UserStore = 'Cert:\CurrentUser\My'
$MachineStore = 'Cert:\LocalMachine\My'

function Find-SignTool {
    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "$env:ProgramFiles\Windows Kits\10\bin"
    ) | Where-Object { $_ -and (Test-Path $_) }

    $found = foreach ($root in $roots) {
        Get-ChildItem -Path $root -Filter 'signtool.exe' -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -match '\\x64$' }
    }

    # Newest SDK wins. The version is the directory above x64, except in older
    # layouts that put signtool straight into bin\x64 — those sort last rather
    # than crashing the cast.
    $found |
        Sort-Object -Descending -Property @{
            Expression = {
                $name = $_.Directory.Parent.Name
                if ($name -match '^\d+(\.\d+){1,3}$') { [version]$name } else { [version]'0.0.0.0' }
            }
        } |
        Select-Object -First 1 -ExpandProperty FullName
}

function Remove-ThrowawayCertificate([string]$Thumbprint) {
    foreach ($store in $UserStore, $MachineStore) {
        Get-ChildItem $store -ErrorAction SilentlyContinue |
            Where-Object {
                if ($Thumbprint) {
                    $_.Thumbprint -eq $Thumbprint
                }
                else {
                    # Substring, not equality: Windows stores a CN containing
                    # spaces or parentheses quoted, so the subject that comes back
                    # never equals the one it was created with.
                    $_.Subject -like "*$ThrowawayCommonName*"
                }
            } |
            ForEach-Object { Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue }
    }
}

# signtool searches the user store unless told otherwise, so a certificate in the
# machine store is invisible to it without /sm. Resolving the store here also
# turns "signtool: cannot find the certificate" into a message that says which
# stores were actually looked in.
function Resolve-CertificateStore([string]$Thumbprint) {
    foreach ($pair in @(@($UserStore, $false), @($MachineStore, $true))) {
        $hit = Get-ChildItem $pair[0] -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $Thumbprint }
        if ($hit) { return @{ Store = $pair[0]; MachineStore = $pair[1] } }
    }

    return $null
}

if (-not $SignThumbprint) {
    $SignThumbprint = $env:WINDOWS_SIGN_THUMBPRINT
}

$configuredThumbprint = [bool]$SignThumbprint
$ephemeralCert = $null

try {
    if (-not $SignThumbprint -and $SelfSignedSignature) {
        Write-Host '==> Creating a throwaway self-signed certificate' -ForegroundColor Cyan

        # Nothing is added to a trust store: the point is to prove the signing
        # path works, not to make the result look trusted.
        #
        # The user store comes first because it needs no elevation. It fails
        # outright in a session with no user crypto profile — an SSH or service
        # logon, where %APPDATA%\Microsoft\Crypto\Keys does not even exist and
        # CertEnroll returns NTE_PERM — and there the machine store is the only
        # one that will hold a key.
        #
        # Swept first: a run killed between signing and cleanup leaves one behind.
        Remove-ThrowawayCertificate

        foreach ($store in $UserStore, $MachineStore) {
            try {
                $ephemeralCert = New-SelfSignedCertificate `
                    -Type CodeSigningCert `
                    -Subject $ThrowawaySubject `
                    -CertStoreLocation $store `
                    -NotAfter (Get-Date).AddDays(1)

                Write-Host "    created in $store"
                break
            }
            catch {
                Write-Host "    $store unavailable: $(($_.Exception.Message -split "`n")[0])" -ForegroundColor Yellow
            }
        }

        if (-not $ephemeralCert) {
            Fail 'Could not create a throwaway signing certificate in either the user or the machine store.'
        }

        $SignThumbprint = $ephemeralCert.Thumbprint
    }

    if (-not $SignThumbprint) {
        Write-Host '==> Not signing (no certificate configured)' -ForegroundColor Yellow
    }
    else {
        $signtool = Find-SignTool
        if (-not $signtool) {
            Fail 'signtool.exe was not found. Install the Windows SDK, or pass neither -SignThumbprint nor -SelfSignedSignature to build unsigned.'
        }

        $location = Resolve-CertificateStore $SignThumbprint
        if (-not $location) {
            Fail "No certificate with thumbprint $SignThumbprint in $UserStore or $MachineStore."
        }

        Write-Host "==> Signing the launcher (certificate from $($location.Store))" -ForegroundColor Cyan

        # Our own two binaries. Everything else under the staging root is the
        # .NET runtime, already signed by Microsoft.
        $signTargets = @(
            (Join-Path $Staging 'ElixirTorrentWebUI.Launcher.exe'),
            (Join-Path $Staging 'ElixirTorrentWebUI.Launcher.dll')
        ) | Where-Object { Test-Path $_ }

        if (-not $signTargets) {
            Fail "Nothing to sign under $Staging — the launcher was not staged."
        }

        foreach ($target in $signTargets) {
            $signArgs = @('sign', '/sha1', $SignThumbprint, '/fd', 'SHA256')
            if ($location.MachineStore) { $signArgs += '/sm' }
            if ($TimestampUrl) { $signArgs += @('/tr', $TimestampUrl, '/td', 'SHA256') }
            $signArgs += $target

            # The timestamp authority is the only network dependency in the whole
            # build; one hiccup should not fail a release.
            $signed = $false
            foreach ($attempt in 1..3) {
                & $signtool @signArgs | Out-Null
                if ($LASTEXITCODE -eq 0) { $signed = $true; break }
                Write-Host "    signtool attempt $attempt failed (exit $LASTEXITCODE)" -ForegroundColor Yellow
            }

            if (-not $signed) { Fail "signtool could not sign $target" }
        }

        # Verify what was produced, the way the macOS build verifies its codesign.
        foreach ($target in $signTargets) {
            $signature = Get-AuthenticodeSignature -FilePath $target
            $leaf = Split-Path -Leaf $target

            if (-not $signature.SignerCertificate) {
                Fail "No signature landed on $leaf."
            }

            if ($signature.SignerCertificate.Thumbprint -ne $SignThumbprint) {
                Fail "$leaf was signed by $($signature.SignerCertificate.Thumbprint), expected $SignThumbprint."
            }

            # A real certificate has to chain to a trusted root. A throwaway one
            # cannot, and saying so beats printing a status the reader has to
            # interpret.
            if ($configuredThumbprint -and $signature.Status -ne 'Valid') {
                Fail "$leaf signature does not validate: $($signature.Status) — $($signature.StatusMessage)"
            }

            $verdict = if ($configuredThumbprint) {
                "$($signature.Status)"
            }
            else {
                "$($signature.Status) — expected: self-signed, trusted by nobody"
            }

            Write-Host "    $leaf <- $($signature.SignerCertificate.Subject) [$verdict]"
        }
    }
}
finally {
    if ($ephemeralCert) {
        Remove-ThrowawayCertificate $ephemeralCert.Thumbprint

        # Checked rather than assumed: this cleanup silently did nothing once, and
        # a build that leaves a signing certificate behind on every run is worse
        # than one that says it could not remove it.
        if (Resolve-CertificateStore $ephemeralCert.Thumbprint) {
            Write-Host "warning: throwaway certificate $($ephemeralCert.Thumbprint) is still in the store — remove it by hand" -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------- Pack

# The launcher resolves exactly this path at runtime; a ZIP without it is a ZIP
# that cannot start, and nothing else in the pipeline would have noticed.
$StagedRelease = Join-Path $Staging 'rel\bin\elixir_torrent_web_ui.bat'
if (-not (Test-Path $StagedRelease)) {
    Fail "Staging is missing $StagedRelease — the artifact would ship without the server."
}

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
