#Requires -Version 5.1
# xcross installer for Windows - downloads the latest prebuilt binary from
# GitHub Releases, installs it, and puts it on the user PATH.
#
# Usage:
#   irm https://raw.githubusercontent.com/arxdeus/xcross/main/install.ps1 | iex
#   # or, pin a version / change install dir:
#   $env:XCROSS_VERSION = 'v1.2.3'
#   $env:XCROSS_INSTALL_DIR = 'D:\tools\xcross'
#   irm https://raw.githubusercontent.com/arxdeus/xcross/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'arxdeus/xcross'
$Asset = 'xcross-windows-x64.zip'
$Version = if ($env:XCROSS_VERSION) { $env:XCROSS_VERSION } else { 'latest' }
$InstallDir = if ($env:XCROSS_INSTALL_DIR) {
  $env:XCROSS_INSTALL_DIR
} else {
  Join-Path $env:LOCALAPPDATA 'xcross'
}

function Info([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Fail([string]$Message) { Write-Error "error: $Message"; exit 1 }

# --- detect architecture (releases are x64-only) ---------------------------
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne 'AMD64') {
  Fail "prebuilt Windows releases are x64-only (got: $arch); build from source"
}
Info "Detected: Windows/$arch -> $Asset"

# --- resolve download URL --------------------------------------------------
if ($Version -eq 'latest') {
  $url = "https://github.com/$Repo/releases/latest/download/$Asset"
} else {
  $url = "https://github.com/$Repo/releases/download/$Version/$Asset"
}

# --- download and extract to a temp directory ------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) "xcross-install-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $zip = Join-Path $tmp $Asset
  Info "Downloading $Version $Asset..."
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
  if (-not (Test-Path $zip) -or (Get-Item $zip).Length -eq 0) {
    Fail "download failed or empty file: $url"
  }

  $staged = Join-Path $tmp 'staged'
  Expand-Archive -Path $zip -DestinationPath $staged
  if (-not (Test-Path (Join-Path $staged 'bin/xcross.exe'))) {
    Fail 'archive missing bin/xcross.exe'
  }
  if (-not (Test-Path (Join-Path $staged 'lib/sysv_abi_bridge.dll'))) {
    Fail 'archive missing lib/sysv_abi_bridge.dll'
  }

  # --- install (keep the bin/ + lib/ layout so xcross finds ../lib) --------
  Info "Installing to $InstallDir"
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  foreach ($dir in 'bin', 'lib', 'THIRD_PARTY_LICENSES') {
    $dst = Join-Path $InstallDir $dir
    if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
  }
  Copy-Item -Recurse -Force (Join-Path $staged '*') $InstallDir
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# --- verify ----------------------------------------------------------------
$exe = Join-Path $InstallDir 'bin/xcross.exe'
& $exe --help *> $null
if ($LASTEXITCODE -ne 0) { Fail 'installed xcross failed verification' }
Info "Installed and verified: $exe"

# --- put bin on the user PATH (persistent + current session) ---------------
$binDir = Join-Path $InstallDir 'bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$onPath = ($userPath -split ';' | Where-Object { $_ }) -contains $binDir
if (-not $onPath) {
  $newPath = if ($userPath) { "$userPath;$binDir" } else { $binDir }
  [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
  Info "Added $binDir to the user PATH (new terminals pick it up)"
}
if (($env:Path -split ';' | Where-Object { $_ }) -notcontains $binDir) {
  $env:Path = "$env:Path;$binDir"
}

# --- prerequisite hints ----------------------------------------------------
$missing = @()
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
  $missing += 'Swift toolchain:  winget install --id Swift.Toolchain --exact'
}
if (-not (Get-Command clang -ErrorAction SilentlyContinue) -or
    -not (Get-Command ld64.lld -ErrorAction SilentlyContinue)) {
  $missing += 'LLVM:             winget install --id LLVM.LLVM --exact'
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  $missing += 'Flutter:          https://flutter.dev/docs/get-started/install/windows'
}
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

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Green
Write-Host '  xcross setup                              # install pymobiledevice3 & friends'
Write-Host '  xcross sdk install C:\Downloads\Xcode.xip # once'
Write-Host '  xcross auth --apple-id you@example.com'
Write-Host '  xcross tunnel                             # Administrator PowerShell, per reconnect'
Write-Host '  xcross flutter run'
