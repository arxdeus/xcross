#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the xcross host requirements on Windows without a package manager.

.DESCRIPTION
  Used by `xcross setup` when neither winget, Scoop nor Chocolatey is
  installed (or with `xcross setup --manager direct`). Downloads each vendor
  installer itself:

    1. Visual Studio 2022 Build Tools (MSVC + Windows SDK, which Swift links
       against) from https://aka.ms/vs/17/release/vs_BuildTools.exe, run only
       with a valid Microsoft Authenticode signature.
    2. Swift 6.4+ from download.swift.org (latest release, or
       XCROSS_SWIFT_VERSION), run only with a valid Apple signature and, when
       XCROSS_SWIFT_SHA256 is set, a matching SHA-256.
    3. LLVM 20+ from the llvm/llvm-project GitHub release (latest, or
       XCROSS_LLVM_VERSION), checked against GitHub's recorded asset digest
       or XCROSS_LLVM_SHA256. XCROSS_LLVM_DIR picks the install root.
    4. Python 3.13 from python.org (latest 3.13.x, or XCROSS_PYTHON_VERSION),
       checked against python.org's published SHA-256 and the Python Software
       Foundation signature.
    5. pymobiledevice3 into the user site-packages.

  XCROSS_SETUP_ONLY=vs,swift,llvm,python installs just that subset and
  skips pymobiledevice3 and the final check (CI uses it for pinned
  toolchains).

  Every installer is announced with its URL and needs a "y" before it runs.
  -Yes (or XCROSS_SETUP_ASSUME_YES=1, which `xcross setup --yes` sets)
  accepts those prompts up front. Installers that need elevation raise their
  own UAC prompt.

  Flutter stays manual: https://docs.flutter.dev/get-started/install/windows

.PARAMETER Yes
  Install everything without asking.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File direct.ps1
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
# Direct vendor downloads
# ---------------------------------------------------------------------------

# Latest releases unless pinned. A pin with a SHA-256 is checked against it;
# otherwise the GitHub/python.org published digest is used, and the
# Authenticode signer is checked for vendors that sign their installers.
$SwiftPin = $env:XCROSS_SWIFT_VERSION         # e.g. 6.4.0
$SwiftPinSha = $env:XCROSS_SWIFT_SHA256
$LlvmPin = $env:XCROSS_LLVM_VERSION           # e.g. 22.1.8
$LlvmPinSha = $env:XCROSS_LLVM_SHA256
$LlvmDir = $env:XCROSS_LLVM_DIR               # install root, default Program Files\LLVM
$PythonPin = $env:XCROSS_PYTHON_VERSION       # e.g. 3.13.16
# Comma-separated subset of vs,swift,llvm,python to install (default: all).
$Only = @(($env:XCROSS_SETUP_ONLY -split ',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
function Test-Wanted([string]$Component) { $Only.Count -eq 0 -or $Only -contains $Component }

function Get-GitHubRelease([string]$Tag) {
  $api = 'https://api.github.com/repos/llvm/llvm-project/releases/' + $(if ($Tag) { "tags/$Tag" } else { 'latest' })
  return Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'xcross-setup' } $api
}

# Visual Studio Build Tools: Microsoft's bootstrapper, Microsoft-signed.
if ((Test-Wanted 'vs') -and -not (Test-Msvc)) {
  [void](Install-SignedInstaller -Name 'Visual Studio 2022 Build Tools' `
      -Url 'https://aka.ms/vs/17/release/vs_BuildTools.exe' `
      -What 'the MSVC compiler and Windows SDK that Swift for Windows links against (several GB)' `
      -Arguments (@('--passive', '--wait', '--norestart') + $vsAdd) `
      -Signer 'O=Microsoft Corporation')
}

# Swift: swift.org release installer, Apple-signed.
$swiftVersion = Get-SwiftVersion
if ((Test-Wanted 'swift') -and (-not $swiftVersion -or $swiftVersion -lt $MinSwift)) {
  $tag = if ($SwiftPin) {
    "swift-$SwiftPin-RELEASE"
  } else {
    @(Get-JsonArray 'https://www.swift.org/api/v1/install/releases.json')[-1].tag
  }
  $platform = if ($isArm64) { 'windows10-arm64' } else { 'windows10' }
  [void](Install-SignedInstaller -Name ($tag -replace '-RELEASE$' -replace '^swift-', 'Swift ') `
      -Url "https://download.swift.org/$($tag.ToLowerInvariant())/$platform/$tag/$tag-$platform.exe" `
      -What "the Swift $MinSwift+ compiler, runtime and SwiftPM" `
      -Arguments @('/passive', '/norestart') `
      -Signer 'O=Apple Inc.' -Sha256 $SwiftPinSha)
}

# LLVM: GitHub release installer, checked against the digest GitHub records
# for the asset (or the pinned SHA-256).
$llvmBin = if ($LlvmDir) { Join-Path $LlvmDir 'bin' } else { Find-LlvmBin }
if ($llvmBin -and (Test-Path (Join-Path $llvmBin 'clang.exe'))) { Add-UserPath $llvmBin }
$clangMajor = Get-ToolMajor 'clang' 'clang version (\d+)'
if ((Test-Wanted 'llvm') -and (-not $clangMajor -or $clangMajor -lt $MinClang -or -not (Get-Command ld64.lld -ErrorAction SilentlyContinue))) {
  $release = Get-GitHubRelease $(if ($LlvmPin) { "llvmorg-$LlvmPin" })
  $suffix = if ($isArm64) { 'woa64' } else { 'win64' }
  # LLVM 22 ships NSIS .exe installers, LLVM 23+ ships .msi.
  $asset = @($release.assets) | Where-Object { $_.name -match "^LLVM-[\d.]+-$suffix\.(exe|msi)$" } | Select-Object -First 1
  if (-not $asset) {
    Write-Warn "No Windows $suffix installer in LLVM release $($release.tag_name)."
  } else {
    $sha = if ($LlvmPinSha) { $LlvmPinSha } elseif ($asset.digest -like 'sha256:*') { $asset.digest.Substring(7) }
    $arguments = if ($asset.name -like '*.msi') {
      @('/passive', '/norestart') + $(if ($LlvmDir) { @("INSTALLDIR=`"$LlvmDir`"") } else { @() })
    } else {
      @('/S') + $(if ($LlvmDir) { @("/D=$LlvmDir") } else { @() })
    }
    if (Install-SignedInstaller -Name "LLVM $($release.tag_name -replace '^llvmorg-')" `
        -Url $asset.browser_download_url `
        -What "clang/clang++ $MinClang+, llvm-ar and ld64.lld for compiling and linking iOS binaries" `
        -Arguments $arguments -Sha256 $sha) {
      $llvmBin = if ($LlvmDir) { Join-Path $LlvmDir 'bin' } else { Find-LlvmBin }
      if ($llvmBin) { Add-UserPath $llvmBin }
    }
  }
}

# Python: python.org installer, checked against python.org's published
# SHA-256 and signed by the Python Software Foundation.
$python = Find-Python
if ((Test-Wanted 'python') -and -not $python) {
  # Invoke-RestMethod emits a JSON array as one object; Get-JsonArray unrolls it.
  $releases = @(Get-JsonArray 'https://www.python.org/api/v2/downloads/release/?is_published=true&pre_release=false')
  $wanted = if ($PythonPin) { "Python $PythonPin" } else { $null }
  $release = $releases |
    Where-Object { if ($wanted) { $_.name -eq $wanted } else { $_.name -like 'Python 3.13.*' } } |
    Sort-Object release_date | Select-Object -Last 1
  $id = ($release.resource_uri -split '/' | Where-Object { $_ })[-1]
  $label = if ($isArm64) { 'Windows installer (ARM64)' } else { 'Windows installer (64-bit)' }
  $file = @(Get-JsonArray "https://www.python.org/api/v2/downloads/release_file/?release=$id") |
    Where-Object { $_.release -eq $release.resource_uri -and $_.name -eq $label } | Select-Object -First 1
  if (-not $file) {
    Write-Warn "No $label for $($release.name)."
  } elseif (Install-SignedInstaller -Name $release.name -Url $file.url `
      -What 'the Python runtime that hosts pymobiledevice3' `
      -Arguments @('/passive', 'InstallAllUsers=0', 'PrependPath=1', 'Include_launcher=1') `
      -Sha256 $file.sha256_sum -Signer 'O=Python Software Foundation') {
    $python = Find-Python
  }
}

$Hint = @{
  Swift  = 'https://www.swift.org/install/windows/'
  Llvm   = 'https://github.com/llvm/llvm-project/releases'
  Python = 'https://www.python.org/downloads/windows/'
}

# Partial runs (XCROSS_SETUP_ONLY) stop here: the summary below checks the
# whole host, including parts this run was told to skip.
if ($Only.Count -gt 0) {
  Write-Info "Installed requested components: $($Only -join ', ')"
  exit 0
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
