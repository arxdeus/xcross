import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final String _packageRoot = Directory.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:apple_developer_kit/'))!,
).parent.path;

void main() {
  test('host-specific native bindings retain the stable code asset id', () {
    final hook = File(p.join(_packageRoot, 'hook', 'build.dart'));
    final declared = RegExp(
      r"_assetName\s*=\s*'([^']+)'",
    ).firstMatch(hook.readAsStringSync())?.group(1);
    expect(
      declared,
      'src/host/shared/adi/loader/internal/sysv_abi_bridge.dart',
    );

    const bindings = {
      'src/host/shared/adi/loader/internal/posix_native_bindings.dart': [
        'provision_clear_cache',
        'provision_posix_symbol',
      ],
      'src/host/windows/adi/loader/internal/windows_abi_bridge.dart': [
        'provision_sysv_wrap_export',
        'provision_sysv_wrap_import',
        'provision_windows_arm64_prepare_code',
      ],
    };

    final natives = Directory(p.join(_packageRoot, 'lib'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => file.readAsStringSync().contains('@Native<'))
        .map(
          (file) => p
              .relative(file.path, from: p.join(_packageRoot, 'lib'))
              .replaceAll(r'\', '/'),
        )
        .toList();

    expect(natives, unorderedEquals(bindings.keys));
    expect(File(p.join(_packageRoot, 'lib', declared)).existsSync(), isFalse);

    for (final entry in bindings.entries) {
      final source = File(
        p.join(_packageRoot, 'lib', entry.key),
      ).readAsStringSync();
      final annotations = RegExp(
        r'@Native<[\s\S]+?>\(([\s\S]+?)\)\s*external',
      ).allMatches(source).toList();
      expect(annotations, hasLength(entry.value.length), reason: entry.key);
      final symbols = <String>[];
      for (final annotation in annotations) {
        final arguments = annotation.group(1)!;
        final assetId = RegExp(
          r"assetId:\s*'([^']+)'",
        ).firstMatch(arguments)?.group(1);
        expect(
          assetId,
          'package:apple_developer_kit/$declared',
          reason: entry.key,
        );
        final symbol = RegExp(
          r"symbol:\s*'([^']+)'",
        ).firstMatch(arguments)?.group(1);
        expect(symbol, isNotNull, reason: entry.key);
        symbols.add(symbol!);
      }
      expect(symbols, unorderedEquals(entry.value), reason: entry.key);
    }
  });
}
