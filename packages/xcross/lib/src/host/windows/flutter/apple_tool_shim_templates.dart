import 'package:meta/meta.dart';

@internal
String powerShellQuote(String value) => "'${value.replaceAll("'", "''")}'";

@internal
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

@internal
String renderBatchPowerShellShim(String script) =>
    '''
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0$script" %*
exit /b %errorlevel%
''';

@internal
String renderBatchToolShim(String tool) =>
    '@echo off\n"$tool" %*\nexit /b %errorlevel%\n';

@internal
const batchCodesignShim = '@echo off\nexit /b 0\n';
