import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final String _packageRoot = Directory.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:apple_developer_kit/'))!,
).parent.path;

/// A bare `@Native` external resolves against an asset id equal to the URI of
/// the library that declares it, so moving such a library without moving the
/// asset name in `hook/build.dart` only fails at runtime, deep inside an Apple
/// ID login: "No asset with id ...".
void main() {
  test('the code asset is named after the library declaring @Native', () {
    final hook = File(p.join(_packageRoot, 'hook', 'build.dart'));
    final declared = RegExp(
      r"_assetName\s*=\s*'([^']+)'",
    ).firstMatch(hook.readAsStringSync())?.group(1);
    expect(declared, isNotNull, reason: 'hook/build.dart declares no asset');

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

    expect(natives, [declared]);
  });
}
