import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/flutter_framework_copier.dart';
import 'package:xcross/src/shared/flutter/swiftpm/resource_manifest.dart';

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
      SwiftPmResourceBundle(bundlePath: source),
      SwiftPmResourceBundle(bundlePath: p.join(products, 'kept.bundle')),
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
    'without a manifest, resolves the built bundle links that resolve',
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
      // The SDWebImage layout: `swift build` copies a `.copy` resource that
      // is a relative link back into the checkout as the link itself.
      final checkout = Directory(p.join(tmp.path, 'checkout'))..createSync();
      File(p.join(checkout.path, 'WebImage', 'PrivacyInfo.xcprivacy'))
        ..createSync(recursive: true)
        ..writeAsStringSync('privacy');
      File(p.join(checkout.path, 'Shared', 'outside.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('outside');
      final source = Directory(p.join(checkout.path, 'build', 'Pkg_T.bundle'))
        ..createSync(recursive: true);
      Link(
        p.join(source.path, 'PrivacyInfo.xcprivacy'),
      ).createSync(p.join('..', '..', 'WebImage', 'PrivacyInfo.xcprivacy'));
      Link(
        p.join(source.path, 'gone.txt'),
      ).createSync(p.join('..', '..', 'missing.txt'));
      final dir = Directory(p.join(source.path, 'Dir'))..createSync();
      File(p.join(dir.path, 'own.txt')).writeAsStringSync('own');
      Link(p.join(dir.path, 'internal.txt')).createSync('own.txt');
      Link(
        p.join(dir.path, 'escape.txt'),
      ).createSync(p.join('..', '..', '..', 'Shared', 'outside.txt'));
      final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
      final warnings = <String>[];

      await copier.copyResourceBundles(
        [SwiftPmResourceBundle(bundlePath: source.path)],
        app.path,
        warn: warnings.add,
      );

      final bundle = p.join(app.path, 'Pkg_T.bundle');
      // A resource that is a link is copied as what it points at.
      expect(
        FileSystemEntity.isLinkSync(p.join(bundle, 'PrivacyInfo.xcprivacy')),
        isFalse,
      );
      expect(
        File(p.join(bundle, 'PrivacyInfo.xcprivacy')).readAsStringSync(),
        'privacy',
      );
      // A link inside a directory that stays in the bundle is kept, as Xcode
      // copies directory contents verbatim.
      final internal = p.join(bundle, 'Dir', 'internal.txt');
      expect(FileSystemEntity.isLinkSync(internal), isTrue);
      expect(Link(internal).targetSync(), 'own.txt');
      expect(File(internal).readAsStringSync(), 'own');
      // One that escapes the bundle would dangle in the app: its target is
      // copied instead.
      final escape = p.join(bundle, 'Dir', 'escape.txt');
      expect(FileSystemEntity.isLinkSync(escape), isFalse);
      expect(File(escape).readAsStringSync(), 'outside');
      // A dangling link is dropped with a warning.
      expect(File(p.join(bundle, 'gone.txt')).existsSync(), isFalse);
      expect(warnings, [contains('gone.txt')]);
      // Nothing in the app points outside the bundle.
      for (final link in Directory(
        bundle,
      ).listSync(recursive: true, followLinks: false).whereType<Link>()) {
        expect(
          p.isWithin(
            bundle,
            p.normalize(p.join(p.dirname(link.path), link.targetSync())),
          ),
          isTrue,
          reason: link.path,
        );
      }
    },
  );
}
