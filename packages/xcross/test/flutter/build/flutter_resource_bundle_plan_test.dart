import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/flutter_framework_copier.dart';
import 'package:xcross/src/shared/flutter/swiftpm/resource_manifest.dart';

import '../../apple/support/native_test_file_system.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('xcross-plan-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  FlutterFrameworkCopier copierFor() {
    const fileSystem = NativeTestFileSystem();
    return FlutterFrameworkCopier(
      fileSystem,
      p.context,
      copier: RecursiveDirectoryCopier(
        fileSystem: fileSystem,
        paths: p.context,
      ),
    );
  }

  String write(String path, String content) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    return path;
  }

  test('a built file and a covered resource in another casing plan one '
      'entry with the source casing', () {
    final source = write(
      p.join(tmp.path, 'src', 'en_GB.lproj', 'G.strings'),
      'source',
    );
    final built = p.join(tmp.path, 'debug', 'G_G.bundle');
    write(p.join(built, 'en_gb.lproj', 'G.strings'), 'built');
    final generated = write(p.join(built, 'en_gb.lproj', 'extra.txt'), 'x');
    final plist = write(p.join(built, 'Info.plist'), 'plist');

    final plan = copierFor().planResourceBundle(
      SwiftPmResourceBundle(
        bundlePath: built,
        resources: [
          SwiftPmBundleResource(
            source: source,
            relative: p.join('en_GB.lproj', 'G.strings'),
          ),
        ],
      ),
    );

    expect(plan, {
      'Info.plist': BundleFile(plist),
      'en_GB.lproj': const BundleDirectory(),
      p.join('en_GB.lproj', 'G.strings'): BundleFile(source, compile: true),
      p.join('en_GB.lproj', 'extra.txt'): BundleFile(generated),
    });
  });

  test('a later resource replaces an earlier one at the same path', () {
    final first = write(p.join(tmp.path, 'a', 'R.txt'), 'a');
    final second = write(p.join(tmp.path, 'b', 'r.txt'), 'b');
    final plan = copierFor().planResourceBundle(
      SwiftPmResourceBundle(
        bundlePath: p.join(tmp.path, 'missing.bundle'),
        resources: [
          SwiftPmBundleResource(source: first, relative: 'R.txt'),
          SwiftPmBundleResource(source: second, relative: 'r.txt'),
        ],
      ),
    );
    expect(plan, {'r.txt': BundleFile(second, compile: true)});
  });

  test(
    testOn: '!windows',
    'a link nested in a resource directory stays a link',
    () {
      final dir = Directory(p.join(tmp.path, 'src', 'Dir'))
        ..createSync(recursive: true);
      final own = write(p.join(dir.path, 'own.txt'), 'own');
      final outside = write(p.join(tmp.path, 'outside.txt'), 'outside');
      Link(p.join(dir.path, 'internal.txt')).createSync('own.txt');
      Link(
        p.join(dir.path, 'escape.txt'),
      ).createSync(p.join('..', '..', 'outside.txt'));
      write(p.join(dir.path, '.DS_Store'), '');

      final plan = copierFor().planResourceBundle(
        SwiftPmResourceBundle(
          bundlePath: p.join(tmp.path, 'missing.bundle'),
          resources: [SwiftPmBundleResource(source: dir.path, relative: 'Dir')],
        ),
      );

      expect(plan, {
        'Dir': const BundleDirectory(),
        p.join('Dir', 'escape.txt'): BundleFile(
          File(outside).resolveSymbolicLinksSync(),
        ),
        p.join('Dir', 'internal.txt'): BundleLink(
          'own.txt',
          p.join(dir.path, 'internal.txt'),
        ),
        p.join('Dir', 'own.txt'): BundleFile(own),
      });
    },
  );

  test('every planned entry is written once and nothing else is', () async {
    final source = write(p.join(tmp.path, 'src', 'P.xcprivacy'), 'source');
    final built = p.join(tmp.path, 'debug', 'P_T.bundle');
    write(p.join(built, 'p.xcprivacy'), 'built');
    write(p.join(built, 'Sub', 'gen.txt'), 'gen');
    final bundle = SwiftPmResourceBundle(
      bundlePath: built,
      resources: [
        SwiftPmBundleResource(source: source, relative: 'P.xcprivacy'),
      ],
    );
    final copier = copierFor();
    final plan = copier.planResourceBundle(bundle);
    final folded = plan.keys.map((key) => key.toLowerCase()).toSet();
    expect(folded, hasLength(plan.length));

    final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
    await copier.copyResourceBundles([bundle], app.path);

    final root = p.join(app.path, 'P_T.bundle');
    final written = {
      for (final entity in Directory(
        root,
      ).listSync(recursive: true, followLinks: false))
        p.relative(entity.path, from: root),
    };
    expect(written, plan.keys.toSet());
    expect(File(p.join(root, 'P.xcprivacy')).readAsStringSync(), 'source');
  });
}
