import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/flutter_framework_copier.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('xcross-bundles-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('copies SwiftPM resource bundles into the app root', () async {
    final host = LinuxHost();
    final copier = FlutterFrameworkCopier(
      host.fileSystem,
      p.context,
      copier: RecursiveDirectoryCopier(
        fileSystem: host.fileSystem,
        paths: p.context,
      ),
    );
    final products = p.join(tmp.path, 'products');
    final source = p.join(products, 'pkg_target.bundle');
    File(p.join(source, 'PrivacyInfo.xcprivacy'))
      ..createSync(recursive: true)
      ..writeAsStringSync('privacy');
    File(p.join(source, 'Info.plist')).writeAsStringSync('info');
    final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
    final existing = Directory(p.join(app.path, 'kept.bundle'))..createSync();

    final copied = await copier.copyResourceBundles([
      source,
      p.join(products, 'kept.bundle'),
    ], app.path);

    expect(copied, [p.join(app.path, 'pkg_target.bundle')]);
    expect(
      File(
        p.join(app.path, 'pkg_target.bundle', 'PrivacyInfo.xcprivacy'),
      ).readAsStringSync(),
      'privacy',
    );
    expect(
      File(p.join(app.path, 'pkg_target.bundle', 'Info.plist')).existsSync(),
      isTrue,
    );
    expect(existing.listSync(), isEmpty);
  });
}
