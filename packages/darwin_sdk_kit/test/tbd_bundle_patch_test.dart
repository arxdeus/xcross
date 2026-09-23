import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:darwin_sdk_kit/src/tbd_architecture_rewrite.dart';
import 'package:darwin_sdk_kit/src/tbd_bundle_patch.dart';
import 'package:darwin_sdk_kit/src/tbd_linker_diagnostic.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_tbd_targets-');
  });

  tearDown(() => tmp.delete(recursive: true));

  String stub(String targets) =>
      '--- !tapi-tbd\n'
      'tbd-version:     4\n'
      'targets:         [ $targets ]\n'
      "install-name:    '/usr/lib/libExample.dylib'\n";

  group('TbdArchitectureRewrite.apply', () {
    test('renames the unparsable slice to the one lld knows', () {
      expect(
        TbdArchitectureRewrite.apply(stub('arm64e-ios, arm64e.x1-ios')),
        stub('arm64e-ios, arm64e-ios'),
      );
    });

    test('leaves a stub without the new architecture untouched', () {
      expect(
        TbdArchitectureRewrite.apply(stub('arm64-ios, arm64e-ios')),
        isNull,
      );
    });

    test('renames rather than deletes, so no target list can empty', () {
      // Deleting the only slice would leave `targets: [ ]`, which the linker
      // rejects just as fatally ("is incompatible with arm64").
      final rewritten = TbdArchitectureRewrite.apply(stub('arm64e.x1-ios'));
      expect(rewritten, stub('arm64e-ios'));
      expect(rewritten, isNot(contains('[  ]')));
    });

    test('covers every place a target may appear, not just targets:', () {
      const document =
          '--- !tapi-tbd\n'
          'tbd-version:     4\n'
          'targets:         [ arm64e-ios, arm64e.x1-ios ]\n'
          "install-name:    '/usr/lib/libExample.dylib'\n"
          'uuids:\n'
          '  - target:          arm64e.x1-ios\n'
          '    value:           00000000-0000-0000-0000-000000000000\n'
          'parent-umbrella:\n'
          '  - targets:         [ arm64e.x1-ios ]\n'
          '    umbrella:        System\n'
          'allowable-clients:\n'
          '  - targets:         [ arm64e.x1-ios ]\n'
          '    clients:         [ Foo ]\n'
          'reexported-libraries:\n'
          '  - targets:         [ arm64e.x1-ios ]\n'
          "    libraries:       [ '/usr/lib/libOther.dylib' ]\n"
          'exports:\n'
          '  - targets:         [ arm64e.x1-ios ]\n'
          '    symbols:         [ _example ]\n';

      final rewritten = TbdArchitectureRewrite.apply(document);
      expect(rewritten, isNotNull);
      expect(rewritten, isNot(contains('arm64e.x1')));
      // Every keyed location the reader accepts a target in, so a rewrite
      // that only handled `targets:` would fail here.
      expect(
        rewritten,
        contains('targets:         [ arm64e-ios, arm64e-ios ]'),
      );
      expect(rewritten, contains('- target:          arm64e-ios'));
      expect(
        '- targets:         [ arm64e-ios ]'.allMatches(rewritten!).length,
        4,
      );
    });

    test('rewrites every document of a multi-document stub', () {
      final rewritten = TbdArchitectureRewrite.apply(
        '${stub('arm64e-ios, arm64e.x1-ios')}'
        '${stub('arm64e.x1-ios')}',
      );
      expect(rewritten, isNot(contains('arm64e.x1')));
    });

    test('leaves symbols that merely end in the token alone', () {
      const document =
          '--- !tapi-tbd\n'
          'targets:         [ arm64e.x1-ios ]\n'
          'exports:\n'
          '  - symbols:       [ _my_arm64e.x1, _OBJC_CLASS_\$_arm64e.x1 ]\n';
      final rewritten = TbdArchitectureRewrite.apply(document);
      expect(rewritten, contains('_my_arm64e.x1'));
      expect(rewritten, contains(r'_OBJC_CLASS_$_arm64e.x1'));
      expect(rewritten, contains('targets:         [ arm64e-ios ]'));
    });

    test('is idempotent', () {
      final once = TbdArchitectureRewrite.apply(
        stub('arm64e-ios, arm64e.x1-ios'),
      )!;
      expect(TbdArchitectureRewrite.apply(once), isNull);
    });
  });

  group('TbdBundlePatch.rewriteBytes', () {
    test('rewrites stub bytes', () {
      final rewritten = TbdBundlePatch.rewriteBytes(
        Uint8List.fromList(utf8.encode(stub('arm64e.x1-ios'))),
      );
      expect(utf8.decode(rewritten!), stub('arm64e-ios'));
    });

    test('returns null for bytes with nothing to rewrite', () {
      expect(
        TbdBundlePatch.rewriteBytes(
          Uint8List.fromList(utf8.encode(stub('arm64'))),
        ),
        isNull,
      );
    });

    test('does not choke on bytes that are not valid UTF-8', () {
      final bytes = Uint8List.fromList([
        ...utf8.encode(stub('arm64e.x1-ios')),
        0xFF,
        0xFE,
      ]);
      final rewritten = TbdBundlePatch.rewriteBytes(bytes)!;
      expect(rewritten.sublist(rewritten.length - 2), [0xFF, 0xFE]);
      expect(latin1.decode(rewritten), contains('arm64e-ios'));
    });
  });

  group('TbdBundlePatch.isTbdName', () {
    test('matches text stubs regardless of case', () {
      expect(TbdBundlePatch.isTbdName('/sdk/usr/lib/libSystem.tbd'), isTrue);
      expect(TbdBundlePatch.isTbdName('/sdk/usr/lib/libSystem.TBD'), isTrue);
      expect(TbdBundlePatch.isTbdName('/sdk/usr/lib/libSystem.dylib'), isFalse);
      expect(TbdBundlePatch.isTbdName('/sdk/usr/include/tbd'), isFalse);
    });
  });

  group('TbdBundlePatch.apply', () {
    Future<String> writeStub(String relative, String targets) async {
      final file = File(p.join(tmp.path, relative));
      await file.parent.create(recursive: true);
      await file.writeAsString(stub(targets));
      return file.path;
    }

    test('rewrites stubs anywhere in the bundle and counts them', () async {
      final nested = await writeStub(
        p.join('Developer', 'SDKs', 'iPhoneOS27.0.sdk', 'A.tbd'),
        'arm64e-ios, arm64e.x1-ios',
      );
      final untouched = await writeStub('B.tbd', 'arm64-ios, arm64e-ios');
      final notAStub = File(p.join(tmp.path, 'C.txt'))
        ..writeAsStringSync(stub('arm64e.x1-ios'));

      final result = TbdBundlePatch.apply(tmp.path);

      expect(result.patched, 1);
      expect(result.complete, isTrue);
      expect(File(nested).readAsStringSync(), isNot(contains('arm64e.x1')));
      expect(File(untouched).readAsStringSync(), stub('arm64-ios, arm64e-ios'));
      expect(notAStub.readAsStringSync(), contains('arm64e.x1'));
    });

    test('is a no-op on a bundle that does not exist', () {
      final result = TbdBundlePatch.apply(p.join(tmp.path, 'missing'));
      expect(result.patched, 0);
      expect(result.complete, isTrue);
    });

    test(
      'does not follow symlinks, so a link target is patched once',
      () async {
        final real = await writeStub('real.tbd', 'arm64e.x1-ios');
        final link = Link(p.join(tmp.path, 'alias.tbd'));
        try {
          link.createSync('real.tbd');
        } on FileSystemException {
          return; // Unprivileged Windows has no symlinks; nothing to assert.
        }

        expect(TbdBundlePatch.apply(tmp.path).patched, 1);
        expect(File(real).readAsStringSync(), stub('arm64e-ios'));
      },
    );

    test(
      'counts a stub it cannot write instead of reporting success',
      () async {
        if (Platform.isWindows) return; // chmod does not deny writes there.
        final path = await writeStub('readonly.tbd', 'arm64e.x1-ios');
        await Process.run('chmod', ['444', path]);
        addTearDown(() => Process.run('chmod', ['644', path]));

        final result = TbdBundlePatch.apply(tmp.path);

        expect(result.patched, 0);
        expect(result.failed, 1);
        expect(result.complete, isFalse);
      },
    );
  });

  group('TbdBundlePatch.ensureApplied', () {
    test('patches an unstamped bundle and stamps it', () async {
      final file = File(p.join(tmp.path, 'libExample.tbd'));
      await file.writeAsString(stub('arm64e-ios, arm64e.x1-ios'));

      expect(TbdBundlePatch.ensureApplied(tmp.path), 1);
      expect(file.readAsStringSync(), stub('arm64e-ios, arm64e-ios'));
      expect(TbdBundlePatch.isStamped(tmp.path), isTrue);

      final stamp = jsonDecode(
        File(p.join(tmp.path, TbdBundlePatch.stampName)).readAsStringSync(),
      );
      expect((stamp as Map)['patchVersion'], TbdBundlePatch.patchVersion);
      expect(stamp['files'], 1);
    });

    test('skips a stamped bundle instead of rescanning it', () async {
      TbdBundlePatch.stamp(tmp.path, files: 0);
      final file = File(p.join(tmp.path, 'libLater.tbd'));
      await file.writeAsString(stub('arm64e.x1-ios'));

      expect(TbdBundlePatch.ensureApplied(tmp.path), 0);
      expect(file.readAsStringSync(), contains('arm64e.x1'));
    });

    test('re-runs when the recorded patch version is older', () async {
      File(p.join(tmp.path, TbdBundlePatch.stampName)).writeAsStringSync(
        jsonEncode({'patchVersion': TbdBundlePatch.patchVersion - 1}),
      );
      final file = File(p.join(tmp.path, 'libExample.tbd'));
      await file.writeAsString(stub('arm64e.x1-ios'));

      expect(TbdBundlePatch.ensureApplied(tmp.path), 1);
      expect(file.readAsStringSync(), stub('arm64e-ios'));
    });

    test('re-runs when the stamp is unreadable', () async {
      File(
        p.join(tmp.path, TbdBundlePatch.stampName),
      ).writeAsStringSync('not json');
      final file = File(p.join(tmp.path, 'libExample.tbd'));
      await file.writeAsString(stub('arm64e.x1-ios'));

      expect(TbdBundlePatch.ensureApplied(tmp.path), 1);
      expect(TbdBundlePatch.isStamped(tmp.path), isTrue);
    });

    test('stamps a bundle that needed no rewrite', () async {
      await File(
        p.join(tmp.path, 'libExample.tbd'),
      ).writeAsString(stub('arm64-ios, arm64e-ios'));

      expect(TbdBundlePatch.ensureApplied(tmp.path), 0);
      expect(TbdBundlePatch.isStamped(tmp.path), isTrue);
    });

    test('leaves a bundle it could not fully rewrite unstamped', () async {
      if (Platform.isWindows) return; // chmod does not deny writes there.
      final path = p.join(tmp.path, 'readonly.tbd');
      await File(path).writeAsString(stub('arm64e.x1-ios'));
      await Process.run('chmod', ['444', path]);
      addTearDown(() => Process.run('chmod', ['644', path]));

      expect(TbdBundlePatch.ensureApplied(tmp.path), 0);
      // Unstamped, so a later run with the right permissions retries rather
      // than trusting a repair that never happened.
      expect(TbdBundlePatch.isStamped(tmp.path), isFalse);
    });
  });

  group('TbdLinkerDiagnostic', () {
    test('recognizes the linker diagnostic this rewrite exists for', () {
      const output =
          'ld64.lld: error: could not load TAPI file at '
          '/home/u/.config/xcross/swift-sdks/xcross-darwin.artifactbundle/'
          'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/'
          'iPhoneOS.sdk/System/Library/Frameworks/UIKit.framework/UIKit.tbd: '
          'malformed file\n'
          'UIKit.tbd:3:32: error: unknown architecture\n'
          'targets: [ arm64e-ios, arm64e.x1-ios ]\n';
      expect(TbdLinkerDiagnostic.reportsUnknownArchitecture(output), isTrue);
    });

    test('ignores unrelated linker failures', () {
      expect(
        TbdLinkerDiagnostic.reportsUnknownArchitecture(
          'ld64.lld: error: undefined symbol: _main',
        ),
        isFalse,
      );
      expect(
        TbdLinkerDiagnostic.reportsUnknownArchitecture(
          'ld64.lld: error: could not load TAPI file at x.tbd: malformed file',
        ),
        isFalse,
      );
    });

    test('names the bundle and the stamp in its guidance', () {
      final guidance = TbdLinkerDiagnostic.guidance('/sdk/bundle');
      expect(guidance, contains('arm64e.x1'));
      expect(
        guidance,
        contains(p.join('/sdk/bundle', TbdBundlePatch.stampName)),
      );
      expect(guidance, contains('xcross sdk install'));
    });

    group('explainFailures', () {
      test('returns the link result untouched when it succeeds', () async {
        final result = await TbdLinkerDiagnostic.explainFailures(
          () async => 'linked',
          bundle: '/sdk/bundle',
          wrap: FormatException.new,
        );
        expect(result, 'linked');
      });

      test('replaces the unknown-architecture failure with guidance', () async {
        await expectLater(
          TbdLinkerDiagnostic.explainFailures<void>(
            () async => throw const FormatException(
              'ld64.lld: error: could not load TAPI file at UIKit.tbd: '
              'malformed file\nUIKit.tbd:3:32: error: unknown architecture',
            ),
            bundle: '/sdk/bundle',
            wrap: _TestLinkError.new,
          ),
          throwsA(
            isA<_TestLinkError>()
                .having((e) => e.message, 'message', contains('arm64e.x1'))
                // The original diagnostic is kept: the guidance explains it,
                // it does not hide what the linker actually said.
                .having(
                  (e) => e.message,
                  'message',
                  contains('unknown architecture'),
                ),
          ),
        );
      });

      test('lets every other linker failure through unchanged', () async {
        await expectLater(
          TbdLinkerDiagnostic.explainFailures<void>(
            () async => throw const FormatException('undefined symbol: _main'),
            bundle: '/sdk/bundle',
            wrap: _TestLinkError.new,
          ),
          throwsA(isA<FormatException>()),
        );
      });
    });
  });
}

/// Stands in for the build-specific error types the real call sites pass
/// (`FlutterBuildError`, `XcrossError`), which live in another package.
final class _TestLinkError implements Exception {
  const _TestLinkError(this.message);

  final String message;
}
