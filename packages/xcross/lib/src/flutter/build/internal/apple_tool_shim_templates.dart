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

String renderUnixOtoolShim({required String tool, required bool usesObjdump}) =>
    usesObjdump
    ? '''
#!/bin/sh
case "\${1-}" in
  -L) shift; exec ${shellQuote(tool)} --macho --dylibs-used "\$@";;
  -D) shift; exec ${shellQuote(tool)} --macho --dylib-id "\$@";;
  -l) shift; exec ${shellQuote(tool)} --macho --private-headers "\$@";;
  --version) exec ${shellQuote(tool)} --version;;
  *) echo "otool: unsupported option \${1-}" >&2; exit 64;;
esac
'''
    : renderUnixToolShim(tool);

String renderPowerShellOtoolShim({
  required String tool,
  required bool usesObjdump,
}) => usesObjdump
    ? '''
\$ToolArguments = \$args
if (\$ToolArguments.Count -eq 0) { Write-Error 'otool: missing option'; exit 64 }
\$option = \$ToolArguments[0]
\$tail = if (\$ToolArguments.Count -gt 1) { \$ToolArguments[1..(\$ToolArguments.Count - 1)] } else { @() }
\$translated = switch (\$option) {
  '-L' { @('--macho', '--dylibs-used') }
  '-D' { @('--macho', '--dylib-id') }
  '-l' { @('--macho', '--private-headers') }
  '--version' { @('--version') }
  default { Write-Error "otool: unsupported option \$option"; exit 64 }
}
& ${powerShellQuote(tool)} @(\$translated + \$tail)
exit \$LASTEXITCODE
'''
    : '''
param([Parameter(ValueFromRemainingArguments = \$true)][string[]]\$Arguments)
& ${powerShellQuote(tool)} @Arguments
exit \$LASTEXITCODE
''';

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
