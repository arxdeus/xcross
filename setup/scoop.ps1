#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the xcross host requirements on Windows with Scoop.

.DESCRIPTION
  What this script does, in order:

    1. Visual Studio 2022 Build Tools with the MSVC and Windows SDK
       components (Swift for Windows links against them), unless present.
       Scoop's official buckets do not carry it, so the Microsoft bootstrapper
       (https://aka.ms/vs/17/release/vs_BuildTools.exe) is downloaded and run
       only with a valid Microsoft Authenticode signature.
    2. Swift toolchain 6.4+ (main/swift, which also sets SDKROOT).
    3. LLVM 20+ (main/llvm) for clang, llvm-ar and ld64.lld.
    4. Python 3 (main/python), unless a Python 3 already exists.
    5. pymobiledevice3 into the user site-packages.

  Run it from a normal (non-Administrator) PowerShell; Scoop installs per
  user. Every package or installer is announced with its source URL and needs
  a "y" before it is installed. -Yes (or XCROSS_SETUP_ASSUME_YES=1, which
  `xcross setup --yes` sets) accepts those prompts up front.

  winget and Chocolatey users: see winget.ps1 and choco.ps1 next to this file.
  Flutter stays manual: https://docs.flutter.dev/get-started/install/windows

.PARAMETER Yes
  Install everything without asking.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scoop.ps1
#>
[CmdletBinding()]
param(
  [Alias('y')]
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 may still default to TLS 1.0.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$AssumeYes = $Yes.IsPresent -or ($env:XCROSS_SETUP_ASSUME_YES -eq '1')

$MinClang = 20
$MinLld = 19
$MinSwift = [version]'6.4'

function Write-Info([string]$Message) { Write-Host "==> $Message" }
function Write-Warn([string]$Message) { Write-Warning $Message }

$CanPrompt = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

# Ask before installing third-party software. Returns $true to proceed.
function Confirm-Install([string]$Name, [string]$Url, [string]$What) {
  Write-Host ''
  Write-Host "xcross setup wants to install $Name"
  Write-Host "  from: $Url"
  Write-Host "  what: $What"
  if ($AssumeYes) {
    Write-Host 'Proceeding (-Yes).'
    return $true
  }
  if (-not $CanPrompt) {
    Write-Warn "No terminal to confirm $Name; skipping it (re-run with -Yes to accept)."
    return $false
  }
  $answer = Read-Host "Install $Name? [y/N]"
  if ($answer -match '^(y|yes)$') { return $true }
  Write-Host "Skipped $Name."
  return $false
}

# Re-read PATH and SDKROOT from the registry so newly installed tools resolve
# in this session without a new terminal.
function Update-SessionEnvironment {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
  foreach ($scope in 'User', 'Machine') {
    $sdk = [Environment]::GetEnvironmentVariable('SDKROOT', $scope)
    if ($sdk) { $env:SDKROOT = $sdk; break }
  }
}

function Add-UserPath([string]$Directory) {
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = @($user -split ';' | Where-Object { $_ })
  if ($entries -notcontains $Directory) {
    [Environment]::SetEnvironmentVariable('Path', (($entries + $Directory) -join ';'), 'User')
    Write-Info "Added $Directory to the user PATH"
  }
  if ((@($env:Path -split ';') -notcontains $Directory)) {
    $env:Path = "$Directory;$env:Path"
  }
}

# Run a native command, returning its combined output and exit code. Windows
# PowerShell 5.1 turns redirected native stderr into terminating errors under
# ErrorActionPreference=Stop, so probes relax it locally.
function Invoke-Probe([string]$Path, [string[]]$Arguments) {
  $ErrorActionPreference = 'Continue'
  $output = (& $Path @Arguments 2>&1 | Out-String)
  return @{ Output = $output; Code = $LASTEXITCODE }
}

# Run a native command with its output on the console; returns the exit code.
# Output goes to the host, not the pipeline, or callers would receive the
# command's stdout as part of the return value.
function Invoke-Native([string]$Path, [string[]]$Arguments) {
  Write-Info "$Path $($Arguments -join ' ')"
  $ErrorActionPreference = 'Continue'
  & $Path @Arguments | Out-Host
  return $LASTEXITCODE
}

function Get-ToolMajor([string]$Command, [string]$Pattern) {
  $tool = Get-Command $Command -ErrorAction SilentlyContinue
  if (-not $tool) { return $null }
  $text = (Invoke-Probe $tool.Source @('--version')).Output
  if ($text -match $Pattern) { return [int]$Matches[1] }
  return $null
}

function Get-SwiftVersion {
  $swift = Get-Command swift -ErrorAction SilentlyContinue
  if (-not $swift) { return $null }
  $text = (Invoke-Probe $swift.Source @('--version')).Output
  if ($text -match 'Swift version (\d+\.\d+)') { return [version]$Matches[1] }
  return $null
}

# The Microsoft Store "python.exe" alias is a stub that only opens the Store.
function Find-Python {
  foreach ($candidate in @(
      @{ Command = 'py'; Args = @('-3') },
      @{ Command = 'python'; Args = @() },
      @{ Command = 'python3'; Args = @() })) {
    $cmd = Get-Command $candidate.Command -ErrorAction SilentlyContinue
    if (-not $cmd -or $cmd.Source -like '*\WindowsApps\*') { continue }
    $probeArgs = $candidate.Args + @('-c', 'import sys; assert sys.version_info >= (3, 9)')
    if ((Invoke-Probe $cmd.Source $probeArgs).Code -eq 0) { return @{ Path = $cmd.Source; Args = $candidate.Args } }
  }
  return $null
}

# Native architecture, even from an emulated x64 PowerShell on ARM64.
$arch = $env:PROCESSOR_ARCHITEW6432
if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
$isArm64 = $arch -eq 'ARM64'

# MSVC + Windows SDK components Swift for Windows links against.
$vcComponent = if ($isArm64) {
  'Microsoft.VisualStudio.Component.VC.Tools.ARM64'
} else {
  'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
}
$vsComponents = @(
  'Microsoft.VisualStudio.Component.Windows11SDK.22621',
  'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
)
if ($isArm64) { $vsComponents += 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' }
$vsAdd = @($vsComponents | ForEach-Object { '--add'; $_ })

function Test-Msvc {
  $programFilesX86 = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { $env:ProgramFiles }
  if (-not $programFilesX86) { return $false }
  $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) { return $false }
  $found = Invoke-Probe $vswhere @('-latest', '-products', '*', '-requires', $vcComponent, '-property', 'installationPath')
  return $found.Code -eq 0 -and [bool]$found.Output.Trim()
}

function Test-Elevated {
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  } catch {
    return $false # Not Windows.
  }
  return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Download a vendor installer, check it against $Sha256 and/or a valid
# Authenticode signature from $Signer (at least one is required), then run it.
function Install-SignedInstaller {
  param(
    [string]$Name, [string]$Url, [string]$What,
    [string[]]$Arguments, [string]$Signer, [string]$Sha256,
    [int[]]$OkCodes = @(0, 3010)
  )
  if (-not $Signer -and -not $Sha256) { throw "No way to verify the $Name installer." }
  if ($Signer -and -not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
    Write-Warn "Cannot verify the $Name installer signature here; install it manually from $Url."
    return $false
  }
  if (-not (Confirm-Install "$Name (official installer)" $Url $What)) { return $false }
  $file = Join-Path ([IO.Path]::GetTempPath()) ("xcross-" + [IO.Path]::GetFileName(([uri]$Url).AbsolutePath))
  try {
    Write-Info "Downloading $Url"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $file -UseBasicParsing
    if ($Sha256) {
      $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
      if ($hash -ne $Sha256.Trim().ToUpperInvariant()) {
        Write-Warn "Refusing to run ${Name}: SHA-256 $hash, expected $Sha256."
        return $false
      }
      Write-Info "SHA-256 $hash"
    }
    if ($Signer) {
      $signature = Get-AuthenticodeSignature -FilePath $file
      $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '<unsigned>' }
      if ($signature.Status -ne 'Valid' -or $subject -notlike "*$Signer*") {
        Write-Warn "Refusing to run ${Name}: signature $($signature.Status), signer $subject."
        return $false
      }
      Write-Info "Signed by $subject"
    }
    $process = if ($file -like '*.msi') {
      Start-Process -FilePath 'msiexec.exe' -ArgumentList (@('/i', "`"$file`"") + $Arguments) -Wait -PassThru
    } else {
      Start-Process -FilePath $file -ArgumentList $Arguments -Wait -PassThru
    }
    Update-SessionEnvironment
    if ($process.ExitCode -eq 3010) { Write-Warn "$Name asks for a reboot to finish installing." }
    if ($OkCodes -notcontains $process.ExitCode) {
      Write-Warn "$Name installer failed with exit code $($process.ExitCode)."
      return $false
    }
    return $true
  } finally {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  }
}

# Invoke-RestMethod writes a top-level JSON array to the pipeline as a single
# object in Windows PowerShell 5.1; enumerate it so filters see each element.
function Get-JsonArray([string]$Url) {
  Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'xcross-setup' } $Url | ForEach-Object { $_ }
}

# ---------------------------------------------------------------------------
# Scoop
# ---------------------------------------------------------------------------

if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
  throw 'Scoop was not found. Install it from https://scoop.sh, or use winget.ps1 / choco.ps1.'
}
if (Test-Elevated) {
  # Scoop installs per user and refuses to run elevated by default.
  Write-Warn 'Scoop is meant to run from a non-Administrator terminal; installs may fail or land in the wrong profile.'
}

# Install (or update, when already installed) one app from Scoop's main bucket.
function Install-Scoop {
  param([string]$App, [string]$Name, [string]$What)
  $url = "https://github.com/ScoopInstaller/Main/blob/master/bucket/$App.json"
  if (-not (Confirm-Install "$Name (scoop main/$App)" $url $What)) { return $false }
  $installed = (Invoke-Probe 'scoop' @('prefix', $App)).Code -eq 0
  $code = if ($installed) { Invoke-Native 'scoop' @('update', $App) } else { Invoke-Native 'scoop' @('install', "main/$App") }
  $ErrorActionPreference = 'Stop'
  Update-SessionEnvironment
  if ($code -eq 0) { return $true }
  Write-Warn "Scoop could not install $Name (exit code $code)."
  return $false
}

# Scoop's official buckets have no Visual Studio Build Tools (community
# buckets only wrap this same Microsoft bootstrapper), so download it from
# Microsoft and run it only with a valid Microsoft Authenticode signature.
if (-not (Test-Msvc)) {
  [void](Install-SignedInstaller -Name 'Visual Studio 2022 Build Tools' `
      -Url 'https://aka.ms/vs/17/release/vs_BuildTools.exe' `
      -What 'the MSVC compiler and Windows SDK that Swift for Windows links against (several GB)' `
      -Arguments (@('--passive', '--wait', '--norestart') + $vsAdd) `
      -Signer 'O=Microsoft Corporation')
}

$swiftVersion = Get-SwiftVersion
if (-not $swiftVersion -or $swiftVersion -lt $MinSwift) {
  # The manifest also sets SDKROOT, picked up by Update-SessionEnvironment.
  [void](Install-Scoop -App 'swift' -Name 'Swift toolchain' `
      -What "the Swift $MinSwift+ compiler, runtime and SwiftPM")
}

$clangMajor = Get-ToolMajor 'clang' 'clang version (\d+)'
if (-not $clangMajor -or $clangMajor -lt $MinClang -or -not (Get-Command ld64.lld -ErrorAction SilentlyContinue)) {
  # Scoop's llvm manifest puts its bin on PATH itself.
  [void](Install-Scoop -App 'llvm' -Name 'LLVM' `
      -What "clang/clang++ $MinClang+, llvm-ar and ld64.lld for compiling and linking iOS binaries")
}

$python = Find-Python
if (-not $python) {
  if (Install-Scoop -App 'python' -Name 'Python 3' -What 'the Python runtime that hosts pymobiledevice3') {
    $python = Find-Python
  }
}

$Hint = @{
  Swift  = 'scoop update swift'
  Llvm   = 'scoop update llvm'
  Python = 'scoop install python'
}

# ---------------------------------------------------------------------------
# pymobiledevice3 and summary
# ---------------------------------------------------------------------------

if ($python) {
  Write-Info 'Installing pymobiledevice3 with pip (user site-packages)'
  $pipCode = Invoke-Native $python.Path ($python.Args + @('-m', 'pip', 'install', '--user', '--upgrade', '--prefer-binary', 'pymobiledevice3'))
  $ErrorActionPreference = 'Stop'
  if ($pipCode -ne 0) { Write-Warn 'pip could not install pymobiledevice3.' }
  # pip --user puts console scripts in a per-version Scripts directory.
  $scripts = Invoke-Probe $python.Path ($python.Args + @('-c', "import sysconfig; print(sysconfig.get_path('scripts', 'nt_user'))"))
  $scriptsDir = ($scripts.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
  if ($scripts.Code -eq 0 -and $scriptsDir) { Add-UserPath $scriptsDir.Trim() }
}

$problems = @()
$swiftVersion = Get-SwiftVersion
if (-not $swiftVersion) {
  $problems += 'swift is not on PATH (open a new terminal after installing, or see https://www.swift.org/install/windows/)'
} elseif ($swiftVersion -lt $MinSwift) {
  $problems += "Swift $swiftVersion is older than $MinSwift ($($Hint.Swift))"
}
$clangMajor = Get-ToolMajor 'clang' 'clang version (\d+)'
if (-not $clangMajor -or $clangMajor -lt $MinClang) {
  $problems += "clang on PATH is $(if ($clangMajor) { $clangMajor } else { 'missing' }); Clang $MinClang+ is required ($($Hint.Llvm))"
}
$lldMajor = Get-ToolMajor 'ld64.lld' 'LLD (\d+)\.'
if (-not $lldMajor) {
  $problems += "ld64.lld is not on PATH ($($Hint.Llvm), then add LLVM's bin directory to PATH)"
} elseif ($lldMajor -lt $MinLld) {
  $problems += "ld64.lld is LLD $lldMajor; $MinLld or newer is required for Objective-C plugins"
}
if (-not (Get-Command llvm-ar -ErrorAction SilentlyContinue)) {
  $problems += 'llvm-ar is not on PATH'
}
if (-not $python) {
  $problems += "Python 3 was not found ($($Hint.Python))"
} elseif ((Invoke-Probe $python.Path ($python.Args + @('-c', 'import pymobiledevice3'))).Code -ne 0) {
  $problems += 'pymobiledevice3 is not importable'
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Warn 'Flutter is not on PATH; install it from https://docs.flutter.dev/get-started/install/windows for `xcross flutter`.'
}

if ($problems.Count -gt 0) {
  Write-Host ''
  Write-Host 'Setup finished with problems:' -ForegroundColor Yellow
  $problems | ForEach-Object { Write-Host "  - $_" }
  exit 1
}
Write-Info 'xcross requirements installed. Open a new terminal so PATH changes take effect.'
exit 0
