import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import 'no_deep_imports_test.dart' as boundary;

void main() {
  test('canonical import boundary includes all URI arms but not strings', () {
    final root = Directory.fromUri(
      Isolate.resolvePackageUriSync(Uri.parse('package:xcross/'))!,
    ).parent.parent.parent.path;
    final directory = Directory(
      '$root/.dart_tool/import-boundary-fixtures-$pid',
    )..createSync(recursive: true);
    try {
      const path = 'packages/xcross/test/fixture.g.dart';
      final source = File('${directory.path}/$path');
      source.parent.createSync(recursive: true);
      final foreign =
          'file://${directory.path}/packages/cli_kit/lib/src/shared/contract.dart';
      for (final uri in [
        'package:cli_kit/src/shared/contract.dart',
        'package:cli_kit/shared/../src/shared/contract.dart',
        '../../cli_kit/lib/src/shared/contract.dart',
        foreign,
      ]) {
        source.writeAsStringSync("import '$uri';");
        expect(
          boundary.deepImportViolations(directory.path, [path]),
          hasLength(1),
          reason: uri,
        );
      }
      source.writeAsStringSync(
        "import 'package:cli_kit/shared/contract.dart' if(dart.library.io) 'package:cli_kit/src/shared/contract.dart';",
      );
      expect(
        boundary.deepImportViolations(directory.path, [path]),
        hasLength(1),
      );
      source.writeAsStringSync(
        "// import 'package:cli_kit/src/shared/contract.dart';\nconst text = \"export 'package:cli_kit/src/shared/contract.dart';\";",
      );
      expect(boundary.deepImportViolations(directory.path, [path]), isEmpty);
      source.writeAsStringSync(
        "import 'package:xcross/src/shared/contract.dart';",
      );
      expect(boundary.deepImportViolations(directory.path, [path]), isEmpty);
      source.writeAsStringSync("import 'package:cli_kit/../../escape.dart';");
      expect(
        boundary.deepImportViolations(directory.path, [path]),
        hasLength(1),
      );
      source.writeAsStringSync(
        "import 'package:cli_kit/src/shared/contract.dart'; class Broken {",
      );
      expect(
        boundary.deepImportViolations(directory.path, [path]),
        hasLength(2),
      );
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}
