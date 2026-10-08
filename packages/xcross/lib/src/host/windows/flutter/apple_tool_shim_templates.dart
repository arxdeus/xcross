import 'package:meta/meta.dart';

@internal
String renderBatchOtoolShim({
  required String tool,
  required bool usesObjdump,
}) => usesObjdump
    ? '''
@echo off
setlocal DisableDelayedExpansion
if "%~1"=="" (
  echo otool: missing option 1>&2
  exit /b 64
)
set "XCROSS_OTOOL_OPTION="
if "%~1"=="-L" set "XCROSS_OTOOL_OPTION=--macho --dylibs-used"
if "%~1"=="-D" set "XCROSS_OTOOL_OPTION=--macho --dylib-id"
if "%~1"=="-l" set "XCROSS_OTOOL_OPTION=--macho --private-headers"
if "%~1"=="--version" set "XCROSS_OTOOL_OPTION=--version"
if not defined XCROSS_OTOOL_OPTION (
  echo otool: unsupported option %1 1>&2
  exit /b 64
)
set "XCROSS_OTOOL_TAIL="
if not "%~2"=="" set "XCROSS_OTOOL_TAIL=%*"
if defined XCROSS_OTOOL_TAIL set "XCROSS_OTOOL_TAIL=%XCROSS_OTOOL_TAIL:* =%"
"$tool" %XCROSS_OTOOL_OPTION% %XCROSS_OTOOL_TAIL%
exit /b %errorlevel%
'''
    : renderBatchToolShim(tool);

@internal
const batchRsyncShim = r'''
@echo off
setlocal DisableDelayedExpansion
set "XCROSS_RSYNC_SOURCE="
set "XCROSS_RSYNC_DESTINATION="
set "XCROSS_RSYNC_MODE=/E"
:next
if "%~1"=="" goto copy
set "XCROSS_RSYNC_ARGUMENT=%~1"
shift
if "%XCROSS_RSYNC_ARGUMENT%"=="--delete" set "XCROSS_RSYNC_MODE=/MIR"
if "%XCROSS_RSYNC_ARGUMENT:~0,1%"=="-" goto next
if "%XCROSS_RSYNC_ARGUMENT%"==".DS_Store/" goto next
set "XCROSS_RSYNC_SOURCE=%XCROSS_RSYNC_DESTINATION%"
set "XCROSS_RSYNC_DESTINATION=%XCROSS_RSYNC_ARGUMENT%"
goto next
:copy
if not defined XCROSS_RSYNC_SOURCE exit /b 1
set "XCROSS_RSYNC_SOURCE=%XCROSS_RSYNC_SOURCE:/=\%"
set "XCROSS_RSYNC_DESTINATION=%XCROSS_RSYNC_DESTINATION:/=\%"
if "%XCROSS_RSYNC_SOURCE:~-1%"=="\" goto trim
for %%I in ("%XCROSS_RSYNC_SOURCE%") do set "XCROSS_RSYNC_DESTINATION=%XCROSS_RSYNC_DESTINATION%\%%~nxI"
:trim
if not "%XCROSS_RSYNC_SOURCE:~-1%"=="\" goto run
set "XCROSS_RSYNC_SOURCE=%XCROSS_RSYNC_SOURCE:~0,-1%"
goto trim
:run
robocopy.exe "%XCROSS_RSYNC_SOURCE%" "%XCROSS_RSYNC_DESTINATION%" %XCROSS_RSYNC_MODE% /XD .DS_Store /XF .DS_Store /NFL /NDL /NJH /NJS /NP /R:0 /W:0
if errorlevel 8 exit /b %errorlevel%
exit /b 0
''';

@internal
String renderBatchToolShim(String tool) =>
    '@echo off\n"$tool" %*\nexit /b %errorlevel%\n';

@internal
const batchCodesignShim = '@echo off\nexit /b 0\n';
