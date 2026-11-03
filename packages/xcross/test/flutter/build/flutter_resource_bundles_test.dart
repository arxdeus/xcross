import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/interface_builder/xib_compiler.dart';
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

  group('xib resources', () {
    const fileSystem = NativeTestFileSystem();
    final calls = <String>[];
    late List<String> warnings;
    setUp(() {
      calls.clear();
      warnings = [];
    });

    FlutterFrameworkCopier copierWith(XibCompilation Function(String) result) =>
        FlutterFrameworkCopier(
          fileSystem,
          p.context,
          copier: RecursiveDirectoryCopier(
            fileSystem: fileSystem,
            paths: p.context,
          ),
          compileXib: (xml, {required module, required deploymentTarget}) {
            calls.add('$xml|$module|$deploymentTarget');
            return result(xml);
          },
        );

    String write(String path, String content) {
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
      return path;
    }

    test('compiles processed xibs to nibs, top level and in lproj', () async {
      final sources = p.join(tmp.path, 'pkg', 'Sources', 'gma', 'Res');
      final top = write(p.join(sources, 'A.xib'), 'a');
      final localized = write(p.join(sources, 'en.lproj', 'L.xib'), 'l');
      final copied = write(
        p.join(tmp.path, 'pkg', 'Sources', 'gma', 'C.xib'),
        'c',
      );
      final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
      await copierWith(
        (xml) => XibCompilation.compiled(Uint8List.fromList(xml.codeUnits)),
      ).copyResourceBundles(
        [
          SwiftPmResourceBundle(
            bundlePath: p.join(tmp.path, 'products', 'pkg_gma.bundle'),
            targetName: 'gma',
            minimumOsVersion: '13.0',
            copyRules: const ['C.xib'],
            resources: [
              SwiftPmBundleResource(source: top, relative: 'A.xib'),
              SwiftPmBundleResource(
                source: localized,
                relative: p.join('en.lproj', 'L.xib'),
              ),
              SwiftPmBundleResource(source: copied, relative: 'C.xib'),
            ],
          ),
        ],
        app.path,
        warn: warnings.add,
      );
      final bundle = p.join(app.path, 'pkg_gma.bundle');
      expect(File(p.join(bundle, 'A.nib')).readAsStringSync(), 'a');
      expect(File(p.join(bundle, 'A.xib')).existsSync(), isFalse);
      expect(File(p.join(bundle, 'en.lproj', 'L.nib')).readAsStringSync(), 'l');
      expect(File(p.join(bundle, 'en.lproj', 'L.xib')).existsSync(), isFalse);
      expect(File(p.join(bundle, 'C.xib')).readAsStringSync(), 'c');
      expect(File(p.join(bundle, 'C.nib')).existsSync(), isFalse);
      expect(calls, unorderedEquals(['a|gma|13.0', 'l|gma|13.0']));
      expect(warnings, isEmpty);
    });

    test('keeps an unsupported xib and warns', () async {
      final source = write(p.join(tmp.path, 'src', 'V.xib'), 'v');
      final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
      await copierWith(
        (_) => const XibCompilation.unsupported(['<tableView>']),
      ).copyResourceBundles(
        [
          SwiftPmResourceBundle(
            bundlePath: p.join(tmp.path, 'products', 'pkg_t.bundle'),
            targetName: 't',
            resources: [
              SwiftPmBundleResource(source: source, relative: 'V.xib'),
            ],
          ),
        ],
        app.path,
        warn: warnings.add,
      );
      final bundle = p.join(app.path, 'pkg_t.bundle');
      expect(File(p.join(bundle, 'V.xib')).readAsStringSync(), 'v');
      expect(File(p.join(bundle, 'V.nib')).existsSync(), isFalse);
      expect(warnings.single, contains('V.xib'));
      expect(warnings.single, contains('<tableView>'));
      expect(calls.single, 'v|t|12.0');
    });

    test('compiles xibs of a built bundle without a manifest', () async {
      final built = p.join(tmp.path, 'products', 'pkg_t.bundle');
      write(p.join(built, 'G.xib'), 'g');
      write(p.join(built, 'fr.lproj', 'H.xib'), 'h');
      write(p.join(built, 'S.storyboard'), 's');
      final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
      await copierWith(
        (xml) => XibCompilation.compiled(Uint8List.fromList(xml.codeUnits)),
      ).copyResourceBundles(
        [SwiftPmResourceBundle(bundlePath: built, targetName: 't')],
        app.path,
        warn: warnings.add,
      );
      final bundle = p.join(app.path, 'pkg_t.bundle');
      expect(File(p.join(bundle, 'G.nib')).readAsStringSync(), 'g');
      expect(File(p.join(bundle, 'G.xib')).existsSync(), isFalse);
      expect(File(p.join(bundle, 'fr.lproj', 'H.nib')).readAsStringSync(), 'h');
      expect(File(p.join(bundle, 'S.storyboard')).existsSync(), isTrue);
      expect(warnings.single, contains('storyboard S.storyboard'));
    });
  });
}
