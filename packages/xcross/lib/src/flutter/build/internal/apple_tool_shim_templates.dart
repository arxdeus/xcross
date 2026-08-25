String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

String powerShellQuote(String value) => "'${value.replaceAll("'", "''")}'";

String renderUnixCompilerShim({
  required String iosSdk,
  required String clang,
  required String hostCompiler,
  required String linker,
  required String deploymentTarget,
}) =>
    '''
#!/bin/sh
is_apple_target=false
has_target=false
has_sysroot=false
has_deployment=false
has_fuse_ld=false
has_ld_path=false
expect_target=false
for arg in "\$@"; do
  if \$expect_target; then
    has_target=true
    case "\$arg" in *-apple-*) is_apple_target=true;; esac
    expect_target=false
    continue
  fi
  case "\$arg" in
    -target|--target) expect_target=true;;
    -target=*|--target=*)
      has_target=true
      case "\${arg#*=}" in *-apple-*) is_apple_target=true;; esac;;
    -arch|-arch=*) is_apple_target=true;;
    -miphoneos-version-min=*) is_apple_target=true; has_deployment=true;;
    -mios-simulator-version-min=*) is_apple_target=true;;
    -isysroot|--sysroot|-isysroot=*|--sysroot=*) has_sysroot=true;;
    -fuse-ld=*) has_fuse_ld=true;;
    --ld-path=*) has_ld_path=true;;
  esac
done
\$is_apple_target || exec ${shellQuote(hostCompiler)} "\$@"
\$has_ld_path || set -- ${shellQuote('--ld-path=$linker')} "\$@"
\$has_fuse_ld || set -- ${shellQuote('-fuse-ld=lld')} "\$@"
\$has_deployment || set -- ${shellQuote('-miphoneos-version-min=$deploymentTarget')} "\$@"
\$has_sysroot || set -- ${shellQuote('-isysroot')} ${shellQuote(iosSdk)} "\$@"
\$has_target || set -- ${shellQuote('--target=arm64-apple-ios$deploymentTarget')} "\$@"
exec ${shellQuote(clang)} "\$@"
''';

String renderUnixXcrunShim({
  required String iosSdk,
  required Map<String, String> tools,
}) =>
    '''
#!/bin/sh
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --sdk) shift; [ "\$#" -gt 0 ] && shift;;
    --show-sdk-path) echo ${shellQuote(iosSdk)}; exit 0;;
    --find)
      shift
      case "\${1-}" in
${tools.entries.map((tool) => '        ${tool.key}) echo ${shellQuote(tool.value)};;').join('\n')}
        *) exit 1;;
      esac
      exit 0;;
    *)
      tool="\$1"; shift
      case "\$tool" in
${tools.entries.map((tool) => '        ${tool.key}) exec ${shellQuote(tool.value)} "\$@";;').join('\n')}
        codesign) exit 0;;
        *) echo "xcrun: unknown tool \$tool" >&2; exit 1;;
      esac;;
  esac
done
exit 1
''';

String renderPowerShellCompilerShim({
  required String iosSdk,
  required String clang,
  required String hostCompiler,
  required String linker,
  required String deploymentTarget,
}) =>
    '''
param([Parameter(ValueFromRemainingArguments = \$true)][string[]]\$Arguments)
\$isAppleTarget = \$false; \$hasTarget = \$false; \$hasSysroot = \$false; \$hasDeployment = \$false
\$hasFuseLd = \$false; \$hasLdPath = \$false
for (\$i = 0; \$i -lt \$Arguments.Count; \$i++) {
  \$arg = \$Arguments[\$i]
  \$target = if (\$arg -eq '-target' -or \$arg -eq '--target') { if (++\$i -lt \$Arguments.Count) { \$Arguments[\$i] } } elseif (\$arg -like '-target=*' -or \$arg -like '--target=*') { \$arg.Substring(\$arg.IndexOf('=') + 1) } else { \$null }
  if (\$null -ne \$target) { \$hasTarget = \$true; if (\$target -like '*-apple-*') { \$isAppleTarget = \$true }; continue }
  if (\$arg -eq '-arch' -or \$arg -like '-arch=*' -or \$arg -like '-miphoneos-version-min=*' -or \$arg -like '-mios-simulator-version-min=*') { \$isAppleTarget = \$true }
  if (\$arg -eq '-isysroot' -or \$arg -eq '--sysroot' -or \$arg -like '-isysroot=*' -or \$arg -like '--sysroot=*') { \$hasSysroot = \$true }
  if (\$arg -like '-miphoneos-version-min=*') { \$hasDeployment = \$true }
  if (\$arg -like '-fuse-ld=*') { \$hasFuseLd = \$true }
  if (\$arg -like '--ld-path=*') { \$hasLdPath = \$true }
}
if (!\$isAppleTarget) { & ${powerShellQuote(hostCompiler)} @Arguments; exit \$LASTEXITCODE }
\$defaults = @()
if (!\$hasTarget) { \$defaults += '--target=arm64-apple-ios$deploymentTarget' }
if (!\$hasSysroot) { \$defaults += @('-isysroot', ${powerShellQuote(iosSdk)}) }
if (!\$hasDeployment) { \$defaults += '-miphoneos-version-min=$deploymentTarget' }
if (!\$hasFuseLd) { \$defaults += '-fuse-ld=lld' }
if (!\$hasLdPath) { \$defaults += ${powerShellQuote('--ld-path=$linker')} }
& ${powerShellQuote(clang)} @(\$defaults + \$Arguments)
exit \$LASTEXITCODE
''';

String renderPowerShellXcrunShim({
  required String iosSdk,
  required Map<String, String> tools,
}) {
  final toolMap = tools.entries
      .map((tool) => '${tool.key} = ${powerShellQuote(tool.value)}')
      .join('; ');
  return '''
param([Parameter(ValueFromRemainingArguments = \$true)][string[]]\$Arguments)
\$tools = @{ $toolMap }
for (\$i = 0; \$i -lt \$Arguments.Count; \$i++) {
  switch (\$Arguments[\$i]) {
    '--sdk' { \$i++; continue }
    '--show-sdk-path' { Write-Output ${powerShellQuote(iosSdk)}; exit 0 }
    '--find' {
      if (++\$i -ge \$Arguments.Count -or !\$tools[\$Arguments[\$i]]) { exit 1 }
      Write-Output \$tools[\$Arguments[\$i]]; exit 0
    }
    default {
      if (\$Arguments[\$i] -eq 'codesign') { exit 0 }
      \$tool = \$tools[\$Arguments[\$i]]
      if (!\$tool) { Write-Error "xcrun: unknown tool \$(\$Arguments[\$i])"; exit 1 }
      \$tail = if (\$i + 1 -lt \$Arguments.Count) { \$Arguments[(\$i + 1)..(\$Arguments.Count - 1)] } else { @() }
      & \$tool @tail
      exit \$LASTEXITCODE
    }
  }
}
exit 1
''';
}

String renderBatchPowerShellShim(String script) =>
    '''
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0$script" %*
exit /b %errorlevel%
''';

String renderBatchToolShim(String tool) =>
    '@echo off\n"$tool" %*\nexit /b %errorlevel%\n';

String renderUnixToolShim(String tool) =>
    '#!/bin/sh\nexec ${shellQuote(tool)} "\$@"\n';

const unixCodesignShim = '#!/bin/sh\nexit 0\n';
const batchCodesignShim = '@echo off\nexit /b 0\n';
