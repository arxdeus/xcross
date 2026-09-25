import 'dart:ffi';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';

Future<String> findDartExecutableOnPath({
  bool? windows,
  Map<String, String>? environment,
  bool useConfiguration = true,
}) async {
  final onWindows = windows ?? Platform.isWindows;
  final executable = await ProcessRunner.which(
    'dart',
    environment: environment,
    windows: onWindows,
    useConfiguration: useConfiguration,
    accept: (path) => _isDartLauncher(path, windows: onWindows),
  );
  if (executable == null) {
    throw XcrossError(
      'failed to locate required executable "dart"; install it and ensure '
      'it is available on PATH',
    );
  }
  return p.normalize(p.absolute(executable));
}

bool _isDartLauncher(String path, {required bool windows}) {
  final name = p.basename(path);
  if (!windows) return name == 'dart' && _isExecutableFile(path);

  return switch (name.toLowerCase()) {
    'dart.exe' || 'dart.bat' || 'dart.cmd' => true,
    _ => false,
  };
}

const _anyExecuteBit = 0x49;
const _executeAccess = 1;

bool _isExecutableFile(String path) {
  final stat = FileStat.statSync(path);
  if (stat.type != FileSystemEntityType.file) return false;
  final access = _access;
  if (access == null) return stat.mode & _anyExecuteBit != 0;
  return using(
    (arena) => access(path.toNativeUtf8(allocator: arena), _executeAccess) == 0,
  );
}

final int Function(Pointer<Utf8> path, int mode)? _access = _lookupAccess();

int Function(Pointer<Utf8>, int)? _lookupAccess() {
  if (Platform.isWindows) return null;
  final process = DynamicLibrary.process();
  if (!process.providesSymbol('access')) return null;
  return process.lookupFunction<
    Int32 Function(Pointer<Utf8>, Int32),
    int Function(Pointer<Utf8>, int)
  >('access');
}
