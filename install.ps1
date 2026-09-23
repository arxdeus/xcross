#Requires -Version 5.1
<#
.SYNOPSIS
  Installs xcross on Windows from a prebuilt GitHub release.

.DESCRIPTION
  What this script does, in order:

    1. Confirms this machine matches the published release (x64 only).
    2. Downloads the release zip into a temp directory.
    3. Extracts it and checks the archive contains what we expect.
    4. Replaces any previous installation with the new one.
    5. Runs `xcross --help` to prove the install works.
    6. Puts the bin directory on the user PATH.
    7. Lists any prerequisite toolchains that are missing.

  No Dart toolchain is required: the release ships an ahead-of-time compiled
  executable together with the native DLLs it loads at runtime.

.PARAMETER XCROSS_VERSION
  Environment variable. Release tag to install, e.g. 'v1.2.3'. Default: latest.

.PARAMETER XCROSS_INSTALL_DIR
  Environment variable. Installation root. Default: %LOCALAPPDATA%\xcross.

.EXAMPLE
  irm https://raw.githubusercontent.com/arxdeus/xcross/main/install.ps1 | iex

.EXAMPLE
  # Pin a version and install elsewhere:
  $env:XCROSS_VERSION = 'v1.2.3'
  $env:XCROSS_INSTALL_DIR = 'D:\tools\xcross'
  irm https://raw.githubusercontent.com/arxdeus/xcross/main/install.ps1 | iex
#>

# Turn non-terminating errors (a failed download, a failed copy) into
# terminating ones, so the script stops instead of continuing with bad state.
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 may still default to TLS 1.0, which github.com rejects.
# Force TLS 1.2 before the first web request.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# GitHub repository that publishes the releases.
$Repo = 'arxdeus/xcross'

# The only Windows asset published today; see the architecture check below.
$Asset = 'xcross-windows-x64.zip'

# Release to install: a tag such as 'v1.2.3', or 'latest'.
$Version = if ($env:XCROSS_VERSION) { $env:XCROSS_VERSION } else { 'latest' }

# Installation root. Defaults to a per-user location so the script never needs
# Administrator rights.
$InstallDir = if ($env:XCROSS_INSTALL_DIR) {
  $env:XCROSS_INSTALL_DIR
} else {
  Join-Path $env:LOCALAPPDATA 'xcross'
}

# Directories shipped inside the zip. They are wiped before extraction so an
# upgrade cannot leave stale files from an older release behind.
$PayloadDirs = @('bin', 'lib', 'THIRD_PARTY_LICENSES')

# ---------------------------------------------------------------------------
# Install layout
# ---------------------------------------------------------------------------
#
# The archive keeps the layout produced by `dart build cli`:
#
#   $InstallDir\
#     bin\xcross.exe            the AOT-compiled executable
#     lib\sysv_abi_bridge.dll   native library loaded at startup
#     THIRD_PARTY_LICENSES\     notices for bundled third-party code
#
# At runtime xcross.exe resolves its native libraries relative to itself, as
# `..\lib`. That is why the whole tree is copied verbatim instead of flattening
# the executable into $InstallDir.

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

# Print a progress step.
function Info([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

# Print an error and abort the installation.
function Fail([string]$Message) { Write-Error "error: $Message"; exit 1 }

# ---------------------------------------------------------------------------
# Step 1 — check that this machine can run a prebuilt release
# ---------------------------------------------------------------------------

# PROCESSOR_ARCHITECTURE reports the architecture of the current process. Only
# x64 binaries are published; on arm64 you have to build from source.
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne 'AMD64') {
  Fail "prebuilt Windows releases are x64-only (got: $arch); build from source"
}
Info "Detected: Windows/$arch -> $Asset"

# ---------------------------------------------------------------------------
# Step 2 — resolve the download URL
# ---------------------------------------------------------------------------

# GitHub exposes the newest release under a stable '/latest/download/' path,
# while pinned versions live under '/download/<tag>/'.
$url = if ($Version -eq 'latest') {
  "https://github.com/$Repo/releases/latest/download/$Asset"
} else {
  "https://github.com/$Repo/releases/download/$Version/$Asset"
}

# ---------------------------------------------------------------------------
# Steps 3 and 4 — download, extract, install
# ---------------------------------------------------------------------------

# Stage everything in a uniquely named temp directory so concurrent or failed
# runs cannot collide; the `finally` block below always cleans it up.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "xcross-install-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $zip = Join-Path $tmp $Asset
  Info "Downloading $Version $Asset..."

  # -UseBasicParsing keeps this working on machines where Internet Explorer's
  # engine (the default HTML parser in PowerShell 5.1) is unavailable.
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip

  # Guard against a proxy or mirror returning an empty body with a 200 status.
  if (-not (Test-Path $zip) -or (Get-Item $zip).Length -eq 0) {
    Fail "download failed or empty file: $url"
  }

  # Extract to a staging folder first and verify both halves of the bundle are
  # present, so a malformed release cannot overwrite a working installation.
  $staged = Join-Path $tmp 'staged'
  Expand-Archive -Path $zip -DestinationPath $staged
  if (-not (Test-Path (Join-Path $staged 'bin\xcross.exe'))) {
    Fail 'archive missing bin\xcross.exe'
  }
  if (-not (Test-Path (Join-Path $staged 'bin\xcrun.exe'))) {
    Fail 'archive missing bin\xcrun.exe'
  }
  if (-not (Test-Path (Join-Path $staged 'lib\sysv_abi_bridge.dll'))) {
    Fail 'archive missing lib\sysv_abi_bridge.dll'
  }

  Info "Installing to $InstallDir"
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

  # Remove the previous payload before copying: a plain overwrite would keep
  # files that no longer exist in the new release.
  foreach ($dir in $PayloadDirs) {
    $dst = Join-Path $InstallDir $dir
    if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
  }

  # Copy the staged tree verbatim, preserving the bin\ + lib\ layout.
  Copy-Item -Recurse -Force (Join-Path $staged '*') $InstallDir
} finally {
  # Best effort: a leftover temp directory is not worth failing the install for.
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Step 5 — verify the installed executable actually runs
# ---------------------------------------------------------------------------

# '--help' exercises startup, which includes loading the native DLLs. If the
# lib\ layout were wrong, this is where it would surface.
# '*> $null' discards every output stream, including stderr.
$exe = Join-Path $InstallDir 'bin\xcross.exe'
& $exe --help *> $null
if ($LASTEXITCODE -ne 0) { Fail 'installed xcross failed verification' }
Info "Installed and verified: $exe"

# ---------------------------------------------------------------------------
# Step 6 — put bin\ on the PATH
# ---------------------------------------------------------------------------

$binDir = Join-Path $InstallDir 'bin'

# The persistent user PATH lives in the registry and is what new terminals
# inherit. Appending only when the entry is missing keeps repeated installs
# from growing it without bound. `Where-Object { $_ }` drops the empty strings
# produced by trailing or doubled semicolons.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$onPath = ($userPath -split ';' | Where-Object { $_ }) -contains $binDir
if (-not $onPath) {
  $newPath = if ($userPath) { "$userPath;$binDir" } else { $binDir }
  [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
  Info "Added $binDir to the user PATH (new terminals pick it up)"
}

# The registry change does not affect the already-running process, so patch the
# current session's PATH too — otherwise `xcross` would not resolve until the
# user opens a new terminal.
if (($env:Path -split ';' | Where-Object { $_ }) -notcontains $binDir) {
  $env:Path = "$env:Path;$binDir"
}

# ---------------------------------------------------------------------------
# Step 7 — report missing prerequisites
# ---------------------------------------------------------------------------
#
# xcross drives external toolchains; it cannot install them for you. These are
# hints only — a missing tool is not an installation failure, because you may
# only need the subset relevant to your workflow.

$missing = @()

# Compiles Swift sources when building iOS/macOS targets.
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
  $missing += 'Swift toolchain:  winget install --id Swift.Toolchain --exact'
}

# clang compiles the C/ObjC side; ld64.lld is the Mach-O linker used to produce
# Apple-format binaries off-platform. Both come from LLVM, so they are reported
# as one item.
$clangCommand = Get-Command clang -ErrorAction SilentlyContinue
$clangMajor = $null
if ($clangCommand) {
  $clangVersion = & $clangCommand.Source --version 2>$null | Select-Object -First 1
  if ($clangVersion -match 'version\s+(\d+)') {
    $clangMajor = [int]$Matches[1]
  }
}
if (-not $clangMajor -or $clangMajor -lt 20 -or
    -not (Get-Command ld64.lld -ErrorAction SilentlyContinue)) {
  $missing += 'LLVM (Clang 20+): winget upgrade --id LLVM.LLVM --exact (or winget install --id LLVM.LLVM --exact)'
}

# Needed for `xcross flutter ...`.
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  $missing += 'Flutter:          https://flutter.dev/docs/get-started/install/windows'
}

# Hosts pymobiledevice3, which talks to physical iOS devices. Either the `py`
# launcher or a `python` on PATH is enough.
if (-not (Get-Command py -ErrorAction SilentlyContinue) -and
    -not (Get-Command python -ErrorAction SilentlyContinue)) {
  $missing += 'Python 3:         winget install --id Python.Python.3.12 --exact'
}

if ($missing.Count -gt 0) {
  Write-Host ''
  Write-Host 'Missing prerequisites (install from an Administrator PowerShell):' `
    -ForegroundColor Yellow
  $missing | ForEach-Object { Write-Host "  $_" }
}

# ---------------------------------------------------------------------------
# Done — tell the user what to run next
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Green
Write-Host '  xcross setup                              # install pymobiledevice3 & friends'
Write-Host '  xcross sdk install C:\Downloads\Xcode.xip # once'
Write-Host '  xcross auth --apple-id you@example.com'
Write-Host '  xcross tunnel                             # Administrator PowerShell, per reconnect'
Write-Host '  xcross flutter run'
