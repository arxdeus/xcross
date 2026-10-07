#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the xcross host requirements on Windows with winget.

.DESCRIPTION
  What this script does, in order:

    1. Visual Studio 2022 Build Tools with the MSVC and Windows SDK
       components (Swift for Windows links against them), unless present.
    2. Swift toolchain 6.4+ (Swift.Toolchain).
    3. LLVM 20+ (LLVM.LLVM) for clang, llvm-ar and ld64.lld, with its bin on
       the user PATH.
    4. Python 3.13 (Python.Python.3.13), unless a Python 3 already exists.
    5. pymobiledevice3 into the user site-packages.

  Every package is announced with its id and source URL and needs a "y"
  before it is installed. -Yes (or XCROSS_SETUP_ASSUME_YES=1, which
  `xcross setup --yes` sets) accepts those prompts up front. Installers that
  need elevation raise their own UAC prompt.

  Scoop and Chocolatey users: see scoop.ps1 and choco.ps1 next to this file;
  without any package manager, direct.ps1 downloads the vendor installers.
  Flutter stays manual: https://docs.flutter.dev/get-started/install/windows

.PARAMETER Yes
  Install everything without asking.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File winget.ps1
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

# The LLVM installer does not touch PATH; xcross finds these directories on
# its own, but PATH makes clang usable everywhere.
function Find-LlvmBin {
  foreach ($root in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $root) { continue }
    $bin = Join-Path $root 'LLVM\bin'
    if (Test-Path (Join-Path $bin 'clang.exe')) { return $bin }
  }
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

# ---------------------------------------------------------------------------
# winget
# ---------------------------------------------------------------------------

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw 'winget was not found. Install "App Installer" from https://aka.ms/getwinget, or use scoop.ps1 / choco.ps1.'
}

$WingetNoop = @(
  -1978335189, # 0x8A15002B: no applicable upgrade
  -1978335135  # 0x8A150061: package already installed
)
$WingetNotInstalled = -1978335212 # 0x8A150014: no installed package found

# Install (or, with -Upgrade, upgrade) one winget package after asking.
function Install-Winget {
  param([string]$Id, [string]$Name, [string]$What, [string[]]$Extra = @(), [switch]$Upgrade)
  $url = "https://github.com/microsoft/winget-pkgs/tree/master/manifests/$($Id.Substring(0,1).ToLowerInvariant())/$($Id -replace '\.', '/')"
  if (-not (Confirm-Install "$Name (winget $Id)" $url $What)) { return $false }
  $common = @('--id', $Id, '--exact', '--source', 'winget',
    '--accept-package-agreements', '--accept-source-agreements') + $Extra
  $code = if ($Upgrade) { Invoke-Native 'winget' (@('upgrade') + $common) } else { $WingetNotInstalled }
  # Present but not installed through winget (or not at all): install.
  if ($code -eq $WingetNotInstalled) { $code = Invoke-Native 'winget' (@('install') + $common) }
  $ErrorActionPreference = 'Stop'
  Update-SessionEnvironment
  if ($code -eq 3010) { Write-Warn "$Name asks for a reboot to finish installing." }
  if ($code -eq 0 -or $code -eq 3010 -or $WingetNoop -contains $code) { return $true }
  Write-Warn "winget could not install $Name (exit code $code)."
  return $false
}

if (-not (Test-Msvc)) {
  [void](Install-Winget -Id 'Microsoft.VisualStudio.2022.BuildTools' `
      -Name 'Visual Studio 2022 Build Tools' `
      -What 'the MSVC compiler and Windows SDK that Swift for Windows links against (several GB)' `
      -Extra @('--custom', ($vsAdd -join ' ')))
}

$swiftVersion = Get-SwiftVersion
if (-not $swiftVersion -or $swiftVersion -lt $MinSwift) {
  [void](Install-Winget -Id 'Swift.Toolchain' -Name 'Swift toolchain' `
      -What "the Swift $MinSwift+ compiler, runtime and SwiftPM" -Upgrade:([bool]$swiftVersion))
}

$llvmBin = Find-LlvmBin
if ($llvmBin) { Add-UserPath $llvmBin }
$clangMajor = Get-ToolMajor 'clang' 'clang version (\d+)'
if (-not $clangMajor -or $clangMajor -lt $MinClang -or -not (Get-Command ld64.lld -ErrorAction SilentlyContinue)) {
  if (Install-Winget -Id 'LLVM.LLVM' -Name 'LLVM' `
      -What "clang/clang++ $MinClang+, llvm-ar and ld64.lld for compiling and linking iOS binaries" `
      -Upgrade:([bool]$clangMajor)) {
    $llvmBin = Find-LlvmBin
    if ($llvmBin) { Add-UserPath $llvmBin }
  }
}

$python = Find-Python
if (-not $python) {
  if (Install-Winget -Id 'Python.Python.3.13' -Name 'Python 3.13' `
      -What 'the Python runtime that hosts pymobiledevice3') {
    $python = Find-Python
  }
}

$Hint = @{
  Swift  = 'winget upgrade --id Swift.Toolchain --exact'
  Llvm   = 'winget upgrade --id LLVM.LLVM --exact'
  Python = 'winget install --id Python.Python.3.13 --exact'
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
