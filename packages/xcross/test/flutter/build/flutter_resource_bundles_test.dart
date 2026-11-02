import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/flutter_framework_copier.dart';

import '../../apple/support/native_test_file_system.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('xcross-bundles-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('copies SwiftPM resource bundles into the app root', () async {
    const fileSystem = NativeTestFileSystem();
    final copier = FlutterFrameworkCopier(
      fileSystem,
      p.context,
      copier: RecursiveDirectoryCopier(
        fileSystem: fileSystem,
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

  test(
    testOn: '!windows',
    'materializes symlinked resources and drops dangling links',
    () async {
      const fileSystem = NativeTestFileSystem();
      final copier = FlutterFrameworkCopier(
        fileSystem,
        p.context,
        copier: RecursiveDirectoryCopier(
          fileSystem: fileSystem,
          paths: p.context,
        ),
      );
      // SwiftPM links resources back into the package checkout.
      final checkout = Directory(p.join(tmp.path, 'checkout', 'Resources'))
        ..createSync(recursive: true);
      File(
        p.join(checkout.path, 'PrivacyInfo.xcprivacy'),
      ).writeAsStringSync('privacy');
      Directory(p.join(checkout.path, 'images')).createSync();
      File(p.join(checkout.path, 'images', 'a.png')).writeAsStringSync('png');
      final source = Directory(p.join(tmp.path, 'products', 'Pkg_T.bundle'))
        ..createSync(recursive: true);
      Link(
        p.join(source.path, 'PrivacyInfo.xcprivacy'),
      ).createSync(p.join(checkout.path, 'PrivacyInfo.xcprivacy'));
      Link(
        p.join(source.path, 'images'),
      ).createSync(p.join(checkout.path, 'images'));
      Link(
        p.join(source.path, 'gone.txt'),
      ).createSync(p.join(checkout.path, 'missing.txt'));
      final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();

      await copier.copyResourceBundles([source.path], app.path);

      final bundle = p.join(app.path, 'Pkg_T.bundle');
      final entries = Directory(
        bundle,
      ).listSync(recursive: true, followLinks: false);
      expect(entries.whereType<Link>(), isEmpty);
      expect(
        File(p.join(bundle, 'PrivacyInfo.xcprivacy')).readAsStringSync(),
        'privacy',
      );
      expect(File(p.join(bundle, 'images', 'a.png')).readAsStringSync(), 'png');
      expect(File(p.join(bundle, 'gone.txt')).existsSync(), isFalse);
    },
  );
}
