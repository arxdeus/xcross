import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final factory in [
    'createLinuxNativeLibraryLoader',
    'createMacOSNativeLibraryLoader',
    'createWindowsNativeLibraryLoader',
  ]) {
    test('AOT compiles a program that only stores $factory', () async {
      final temp = await Directory.systemTemp.createTemp('loader_aot_');
      addTearDown(() => temp.delete(recursive: true));
      final entry = File(p.join(temp.path, 'probe.dart'))
        ..writeAsStringSync(
          "import 'package:apple_developer_kit/composition/"
          "native_library_loader.dart';\n"
          'final class Holder {\n'
          '  Holder(this.create);\n'
          '  final Object Function() create;\n'
          '}\n'
          'void main() => print(Holder($factory).hashCode);\n',
        );
      final packages = await Isolate.packageConfig;
      final result = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'aot-snapshot',
        '--packages=${packages!.toFilePath()}',
        '-o',
        p.join(temp.path, 'probe.aot'),
        entry.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });
  }
}
