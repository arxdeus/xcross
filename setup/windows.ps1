#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the xcross host requirements on Windows with winget, Scoop or
  Chocolatey.

.DESCRIPTION
  What this script does, in order:

    1. Visual Studio 2022 Build Tools with the MSVC and Windows SDK
       components (Swift for Windows links against them), unless present.
    2. Swift toolchain 6.4+.
    3. LLVM 20+ for clang, llvm-ar and ld64.lld, with its bin on PATH.
    4. Python 3, unless one already exists.
    5. pymobiledevice3 into the user site-packages.

  Package sources per manager:

                     winget                   Scoop          Chocolatey
    VS Build Tools   Microsoft.VisualStudio.  (direct)       visualstudio2022buildtools
                     2022.BuildTools
    Swift            Swift.Toolchain          main/swift     (direct)
    LLVM             LLVM.LLVM                main/llvm      llvm
    Python           Python.Python.3.13       main/python    python313

  "(direct)" means the manager has no official package, so the official
  installer is downloaded from its vendor (aka.ms for Visual Studio,
  download.swift.org for Swift) and runs only with a valid Authenticode
  signature from Microsoft or Apple respectively.

  Every package or installer is announced with its source URL and needs a
  "y" before it is installed. -Yes (or XCROSS_SETUP_ASSUME_YES=1, which
  `xcross setup --yes` sets) accepts those prompts up front. Installers that
  need elevation raise their own UAC prompt.

  Flutter stays manual: https://docs.flutter.dev/get-started/install/windows

.PARAMETER Manager
  winget, scoop, choco, or auto (default). auto uses the only manager found,
  asks when several are installed, and prefers winget > scoop > choco when it
  cannot ask. XCROSS_SETUP_MANAGER sets the same choice.

.PARAMETER Yes
  Install everything without asking.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File windows.ps1 -Manager scoop
#>
[CmdletBinding()]
param(
  [ValidateSet('auto', 'winget', 'scoop', 'choco')]
  [string]$Manager = 'auto',
  [Alias('y')]
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 may still default to TLS 1.0.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$AssumeYes = $Yes.IsPresent -or ($env:XCROSS_SETUP_ASSUME_YES -eq '1')
if ($Manager -eq 'auto' -and $env:XCROSS_SETUP_MANAGER) { $Manager = $env:XCROSS_SETUP_MANAGER.ToLowerInvariant() }

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

# Re-read PATH and SDKROOT (Scoop's swift sets it) from the registry so newly
# installed tools resolve in this session without a new terminal.
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

function Test-Elevated {
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  } catch {
    return $false # Not Windows.
  }
  return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
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

# Native architecture, even from an emulated x64 PowerShell on ARM64.
$arch = $env:PROCESSOR_ARCHITEW6432
if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
$isArm64 = $arch -eq 'ARM64'

# ---------------------------------------------------------------------------
# Package manager selection
# ---------------------------------------------------------------------------

$ManagerInfo = [ordered]@{
  winget = @{ Command = 'winget'; Get = 'https://aka.ms/getwinget' }
  scoop  = @{ Command = 'scoop'; Get = 'https://scoop.sh' }
  choco  = @{ Command = 'choco'; Get = 'https://chocolatey.org/install' }
}

$available = @($ManagerInfo.Keys | Where-Object { Get-Command $ManagerInfo[$_].Command -ErrorAction SilentlyContinue })
if ($Manager -ne 'auto') {
  if (-not $ManagerInfo.Contains($Manager)) {
    throw "Unknown package manager '$Manager'; use winget, scoop or choco."
  }
  if ($available -notcontains $Manager) {
    throw "$Manager is not on PATH. Install it from $($ManagerInfo[$Manager].Get), or pick another with -Manager."
  }
} elseif ($available.Count -eq 0) {
  throw ('No supported package manager found. Install one of: ' +
    (($ManagerInfo.Keys | ForEach-Object { "$_ ($($ManagerInfo[$_].Get))" }) -join ', '))
} elseif ($available.Count -eq 1 -or $AssumeYes -or -not $CanPrompt) {
  $Manager = $available[0]
} else {
  Write-Host 'Several package managers are installed. Which one should xcross use?'
  for ($i = 0; $i -lt $available.Count; $i++) { Write-Host "  [$($i + 1)] $($available[$i])" }
  while ($true) {
    $raw = Read-Host "Choice (1-$($available.Count))"
    $choice = 0
    if ([int]::TryParse($raw, [ref]$choice) -and $choice -ge 1 -and $choice -le $available.Count) {
      $Manager = $available[$choice - 1]
      break
    }
    Write-Host "Invalid choice '$raw'."
  }
}
Write-Info "Package manager: $Manager"

if ($Manager -eq 'scoop' -and (Test-Elevated)) {
  # Scoop installs per user and refuses to run elevated by default.
  Write-Warn 'Scoop is meant to run from a non-Administrator terminal; installs may fail or land in the wrong profile.'
}
if ($Manager -eq 'choco' -and -not (Test-Elevated)) {
  throw 'Chocolatey installs machine-wide and needs an Administrator PowerShell. Re-run `xcross setup` from one, or pick -Manager winget/scoop.'
}

# winget exit codes that mean "nothing to do", not failure.
$WingetNoop = @(
  -1978335189, # 0x8A15002B: no applicable upgrade
  -1978335135  # 0x8A150061: package already installed
)
$WingetNotInstalled = -1978335212 # 0x8A150014: no installed package found (upgrade)

# Installs one package through the selected manager. $Spec carries a
# per-manager entry; a missing entry means "use $Spec.Direct".
function Install-Package {
  param([hashtable]$Spec, [switch]$Upgrade)
  $entry = $Spec[$Manager]
  if (-not $entry) {
    if ($Spec.Direct) { return (& $Spec.Direct) }
    Write-Warn "$($Spec.Name) has no $Manager package; install it manually."
    return $false
  }
  switch ($Manager) {
    'winget' {
      $url = "https://github.com/microsoft/winget-pkgs/tree/master/manifests/$($entry.Id.Substring(0,1).ToLowerInvariant())/$($entry.Id -replace '\.', '/')"
      if (-not (Confirm-Install "$($Spec.Name) (winget $($entry.Id))" $url $Spec.What)) { return $false }
      $common = @('--id', $entry.Id, '--exact', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements') + @($entry.Extra | Where-Object { $_ })
      $code = if ($Upgrade) { Invoke-Native 'winget' (@('upgrade') + $common) } else { $WingetNotInstalled }
      # Present but not from winget (or not at all): install instead.
      if ($code -eq $WingetNotInstalled) { $code = Invoke-Native 'winget' (@('install') + $common) }
      $ok = $code -eq 0 -or $code -eq 3010 -or $WingetNoop -contains $code
    }
    'scoop' {
      $url = "https://github.com/ScoopInstaller/$($entry.BucketRepo)/blob/master/bucket/$($entry.App).json"
      if (-not (Confirm-Install "$($Spec.Name) (scoop $($entry.Bucket)/$($entry.App))" $url $Spec.What)) { return $false }
      if ($entry.Bucket -ne 'main') {
        $buckets = (Invoke-Probe 'scoop' @('bucket', 'list')).Output
        if ($buckets -notmatch "(?m)^\s*$($entry.Bucket)\b") { [void](Invoke-Native 'scoop' @('bucket', 'add', $entry.Bucket)) }
      }
      $installed = (Invoke-Probe 'scoop' @('prefix', $entry.App)).Code -eq 0
      $code = if ($installed) {
        Invoke-Native 'scoop' @('update', $entry.App)
      } else {
        Invoke-Native 'scoop' @('install', "$($entry.Bucket)/$($entry.App)")
      }
      $ok = $code -eq 0
    }
    'choco' {
      $url = "https://community.chocolatey.org/packages/$($entry.Id)"
      if (-not (Confirm-Install "$($Spec.Name) (choco $($entry.Id))" $url $Spec.What)) { return $false }
      # `choco upgrade` installs missing packages too.
      $arguments = @('upgrade', $entry.Id, '--yes', '--no-progress')
      if ($entry.Params) { $arguments += @('--package-parameters', $entry.Params) }
      $code = Invoke-Native 'choco' $arguments
      $ok = $code -in 0, 1641, 3010
    }
  }
  $ErrorActionPreference = 'Stop'
  Update-SessionEnvironment
  if ($code -eq 3010 -or $code -eq 1641) { Write-Warn "$($Spec.Name) asks for a reboot to finish installing." }
  if (-not $ok) { Write-Warn "$Manager could not install $($Spec.Name) (exit code $code)." }
  return $ok
}

# Download a vendor installer, require a valid Authenticode signature (and
# optionally a signer), then run it.
function Install-SignedInstaller {
  param(
    [string]$Name, [string]$Url, [string]$What,
    [string[]]$Arguments, [string]$Signer, [int[]]$OkCodes = @(0, 3010)
  )
  if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
    Write-Warn "Cannot verify the $Name installer signature here; install it manually from $Url."
    return $false
  }
  if (-not (Confirm-Install "$Name (official installer)" $Url $What)) { return $false }
  $file = Join-Path ([IO.Path]::GetTempPath()) ("xcross-" + [IO.Path]::GetFileName(([uri]$Url).AbsolutePath))
  try {
    Write-Info "Downloading $Url"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $file -UseBasicParsing
    $signature = Get-AuthenticodeSignature -FilePath $file
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '<unsigned>' }
    if ($signature.Status -ne 'Valid' -or ($Signer -and $subject -notlike "*$Signer*")) {
      Write-Warn "Refusing to run ${Name}: signature $($signature.Status), signer $subject."
      return $false
    }
    Write-Info "Signed by $subject"
    $process = Start-Process -FilePath $file -ArgumentList $Arguments -Wait -PassThru
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

# ---------------------------------------------------------------------------
# 1. Visual Studio Build Tools (MSVC + Windows SDK) for Swift
# ---------------------------------------------------------------------------

$vcComponent = if ($isArm64) {
  'Microsoft.VisualStudio.Component.VC.Tools.ARM64'
} else {
  'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
}
$programFilesX86 = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { $env:ProgramFiles }
$vswhere = if ($programFilesX86) {
  Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
}
$haveMsvc = $false
if ($vswhere -and (Test-Path $vswhere)) {
  $found = Invoke-Probe $vswhere @('-latest', '-products', '*', '-requires', $vcComponent, '-property', 'installationPath')
  $haveMsvc = $found.Code -eq 0 -and [bool]$found.Output.Trim()
}
if (-not $haveMsvc) {
  $components = @(
    'Microsoft.VisualStudio.Component.Windows11SDK.22621',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
  )
  if ($isArm64) { $components += 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' }
  $add = ($components | ForEach-Object { "--add $_" }) -join ' '
  [void](Install-Package -Spec @{
      Name   = 'Visual Studio 2022 Build Tools'
      What   = 'the MSVC compiler and Windows SDK that Swift for Windows links against (several GB)'
      winget = @{ Id = 'Microsoft.VisualStudio.2022.BuildTools'; Extra = @('--custom', $add) }
      # The package forwards these to vs_BuildTools.exe; --passive shows
      # progress instead of its default --quiet.
      choco  = @{ Id = 'visualstudio2022buildtools'; Params = "$add --passive" }
      # Scoop's official buckets have no Build Tools; community buckets only
      # wrap this same Microsoft bootstrapper.
      Direct = {
        Install-SignedInstaller `
          -Name 'Visual Studio 2022 Build Tools' `
          -Url 'https://aka.ms/vs/17/release/vs_BuildTools.exe' `
          -What 'the MSVC compiler and Windows SDK that Swift for Windows links against (several GB)' `
          -Arguments (@('--passive', '--wait', '--norestart') + ($add -split ' ')) `
          -Signer 'O=Microsoft Corporation'
      }
    })
}

# ---------------------------------------------------------------------------
# 2. Swift
# ---------------------------------------------------------------------------

# Chocolatey has no official Swift package (the Swift project publishes to
# winget only), so it uses the release installer from swift.org.
$installSwiftDirect = {
  $release = (Invoke-RestMethod -UseBasicParsing 'https://www.swift.org/api/v1/install/releases.json')[-1]
  $tag = $release.tag
  $platform = if ($isArm64) { 'windows10-arm64' } else { 'windows10' }
  $url = "https://download.swift.org/$($tag.ToLowerInvariant())/$platform/$tag/$tag-$platform.exe"
  Install-SignedInstaller `
    -Name "Swift $($release.name)" `
    -Url $url `
    -What "the Swift $MinSwift+ compiler, runtime and SwiftPM" `
    -Arguments @('/passive', '/norestart') `
    -Signer 'O=Apple Inc.'
}

$swiftVersion = Get-SwiftVersion
if (-not $swiftVersion -or $swiftVersion -lt $MinSwift) {
  [void](Install-Package -Upgrade:([bool]$swiftVersion) -Spec @{
      Name   = 'Swift toolchain'
      What   = "the Swift $MinSwift+ compiler, runtime and SwiftPM"
      winget = @{ Id = 'Swift.Toolchain' }
      scoop  = @{ App = 'swift'; Bucket = 'main'; BucketRepo = 'Main' }
      Direct = $installSwiftDirect
    })
}

# ---------------------------------------------------------------------------
# 3. LLVM (clang, llvm-ar, ld64.lld)
# ---------------------------------------------------------------------------

# The winget/choco LLVM installers do not touch PATH (Scoop's does); xcross
# finds these directories on its own, but PATH makes clang usable everywhere.
function Find-LlvmBin {
  foreach ($root in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $root) { continue }
    $bin = Join-Path $root 'LLVM\bin'
    if (Test-Path (Join-Path $bin 'clang.exe')) { return $bin }
  }
  return $null
}

$llvmBin = Find-LlvmBin
if ($llvmBin) { Add-UserPath $llvmBin }
$clangMajor = Get-ToolMajor 'clang' 'clang version (\d+)'
$haveLd64 = [bool](Get-Command ld64.lld -ErrorAction SilentlyContinue)
if (-not $clangMajor -or $clangMajor -lt $MinClang -or -not $haveLd64) {
  if (Install-Package -Upgrade:([bool]$clangMajor) -Spec @{
      Name   = 'LLVM'
      What   = "clang/clang++ $MinClang+, llvm-ar and ld64.lld for compiling and linking iOS binaries"
      winget = @{ Id = 'LLVM.LLVM' }
      scoop  = @{ App = 'llvm'; Bucket = 'main'; BucketRepo = 'Main' }
      choco  = @{ Id = 'llvm' }
    }) {
    $llvmBin = Find-LlvmBin
    if ($llvmBin) { Add-UserPath $llvmBin }
  }
}

# ---------------------------------------------------------------------------
# 4. Python
# ---------------------------------------------------------------------------

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

$python = Find-Python
if (-not $python) {
  if (Install-Package -Spec @{
      Name   = 'Python 3'
      What   = 'the Python runtime that hosts pymobiledevice3'
      winget = @{ Id = 'Python.Python.3.13' }
      scoop  = @{ App = 'python'; Bucket = 'main'; BucketRepo = 'Main' }
      choco  = @{ Id = 'python313' }
    }) {
    $python = Find-Python
  }
}

# ---------------------------------------------------------------------------
# 5. pymobiledevice3
# ---------------------------------------------------------------------------

if ($python) {
  Write-Info 'Installing pymobiledevice3 with pip (user site-packages)'
  $pipArgs = $python.Args + @('-m', 'pip', 'install', '--user', '--upgrade', '--prefer-binary', 'pymobiledevice3')
  $pipCode = Invoke-Native $python.Path $pipArgs
  $ErrorActionPreference = 'Stop'
  if ($pipCode -ne 0) { Write-Warn 'pip could not install pymobiledevice3.' }
  # pip --user puts console scripts in a per-version Scripts directory.
  $scripts = Invoke-Probe $python.Path ($python.Args + @('-c', "import sysconfig; print(sysconfig.get_path('scripts', 'nt_user'))"))
  $scriptsDir = ($scripts.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
  if ($scripts.Code -eq 0 -and $scriptsDir) { Add-UserPath $scriptsDir.Trim() }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$hint = @{
  swift  = @{ winget = 'winget upgrade --id Swift.Toolchain --exact'; scoop = 'scoop update swift'; choco = 'https://www.swift.org/install/windows/' }
  llvm   = @{ winget = 'winget upgrade --id LLVM.LLVM --exact'; scoop = 'scoop update llvm'; choco = 'choco upgrade llvm' }
  python = @{ winget = 'winget install --id Python.Python.3.13 --exact'; scoop = 'scoop install python'; choco = 'choco install python313' }
}

$problems = @()
$swiftVersion = Get-SwiftVersion
if (-not $swiftVersion) {
  $problems += 'swift is not on PATH (open a new terminal after installing, or see https://www.swift.org/install/windows/)'
} elseif ($swiftVersion -lt $MinSwift) {
  $problems += "Swift $swiftVersion is older than $MinSwift ($($hint.swift[$Manager]))"
}
$clangMajor = Get-ToolMajor 'clang' 'clang version (\d+)'
if (-not $clangMajor -or $clangMajor -lt $MinClang) {
  $problems += "clang on PATH is $(if ($clangMajor) { $clangMajor } else { 'missing' }); Clang $MinClang+ is required ($($hint.llvm[$Manager]))"
}
$lldMajor = Get-ToolMajor 'ld64.lld' 'LLD (\d+)\.'
if (-not $lldMajor) {
  $problems += "ld64.lld is not on PATH ($($hint.llvm[$Manager]), then add LLVM's bin directory to PATH)"
} elseif ($lldMajor -lt $MinLld) {
  $problems += "ld64.lld is LLD $lldMajor; $MinLld or newer is required for Objective-C plugins"
}
if (-not (Get-Command llvm-ar -ErrorAction SilentlyContinue)) {
  $problems += 'llvm-ar is not on PATH'
}
if (-not $python) {
  $problems += "Python 3 was not found ($($hint.python[$Manager]))"
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
