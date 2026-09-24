import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/swift_package_host_patches.dart';

String diagnostic(String path) =>
    "$path:12:7: error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found";

void main() {
  test('renames only real State attributes and avoids alias collisions', () {
    const source = r'''
import SwiftUI
struct _XcrossSwiftUIState {}
struct _XcrossSwiftUIState2 {}
// @State and @SwiftUI.State
/* outer /* @State */ @SwiftUI.State */
let plain = "@State"
let raw = #"@SwiftUI.State"#
let escapedRaw = #"before \#"# @State after"#
let regex = /@State/
let rawRegex = #/@SwiftUI.State/#
let multiline = """
@State
"""
struct ViewModel {
  @State var count = 0
  @SwiftUI.State var flag = false
  @Other.State var untouched = 0
  @State.Other var alsoUntouched = 0
  @SwiftUI.State.Other var qualifiedUntouched = 0
  @Stateful var unrelated = 0
}
''';
    final repaired = restoreSwiftUIStatePropertyWrapper(source);
    expect(repaired, contains('@_XcrossSwiftUIState3 var count'));
    expect(repaired, contains('@_XcrossSwiftUIState3 var flag'));
    for (final decoy in [
      '// @State and @SwiftUI.State',
      '/* outer /* @State */ @SwiftUI.State */',
      'let plain = "@State"',
      'let raw = #"@SwiftUI.State"#',
      r'let escapedRaw = #"before \#"# @State after"#',
      'let regex = /@State/',
      'let rawRegex = #/@SwiftUI.State/#',
      '"""\n@State\n"""',
      '@Other.State',
      '@State.Other',
      '@SwiftUI.State.Other',
      '@Stateful',
    ]) {
      expect(repaired, contains(decoy));
    }
    expect(
      repaired,
      contains(
        'private typealias _XcrossSwiftUIState3<Value> = SwiftUI.State<Value>',
      ),
    );
    expect(restoreSwiftUIStatePropertyWrapper(repaired), repaired);
    expect(
      restoreSwiftUIStatePropertyWrapper('// @State\nlet x = "@State"'),
      '// @State\nlet x = "@State"',
    );
  });

  test('division is not mistaken for a regex literal', () {
    // Two slashes on one line used to be read as a bare regex, hiding the
    // `@State` between them so recovery could never converge.
    const source = r'''
import SwiftUI
struct V: View {
  let ratio = width /height; @State var one = 0; let half = total / 2
  var body: some View { Text("\(ratio)") }
}
''';
    final repaired = restoreSwiftUIStatePropertyWrapper(source);
    expect(repaired, contains('@_XcrossSwiftUIState var one'));
    expect(repaired, contains('width /height;'));
    expect(repaired, contains('total / 2'));

    // A regex literal where an expression may start stays masked.
    for (final regexSource in [
      'let r = /@State/',
      'f(/@State/)',
      'return /@State/',
    ]) {
      expect(
        restoreSwiftUIStatePropertyWrapper(regexSource),
        regexSource,
        reason: regexSource,
      );
    }
  });

  group('diagnostic-driven recovery', () {
    late Directory root;
    late Directory vendor;
    late Directory packages;
    setUp(() {
      root = Directory.systemTemp.createTempSync('xcross-state-recovery-');
      vendor = Directory(p.join(root.path, 'vendor'))..createSync();
      packages = Directory(p.join(root.path, 'Packages'))..createSync();
    });
    tearDown(() => root.deleteSync(recursive: true));

    File source(String path) => File(
      path,
    )..writeAsStringSync('import SwiftUI\nstruct V { @State var x = false }\n');
    Future<bool> repair(String output) =>
        GeneratedPluginsPackage.repairMissingSwiftUIStateMacro(
          output,
          ownedRoots: [vendor.path, packages.path],
        );

    test('changes only exact-diagnostic files in owned roots, once', () async {
      final reported = source(p.join(vendor.path, 'View.swift'));
      final staged = source(p.join(packages.path, 'Other.swift'));
      final unreported = source(p.join(vendor.path, 'Unreported.swift'));
      final outside = source(p.join(root.path, 'PubCache.swift'));
      final sibling = Directory('${vendor.path}-outside')..createSync();
      final siblingFile = source(p.join(sibling.path, 'Sibling.swift'));
      final original = reported.readAsStringSync();
      final output = [
        diagnostic(reported.path),
        diagnostic(reported.path),
        diagnostic(staged.path),
        diagnostic(outside.path),
        diagnostic(siblingFile.path),
        diagnostic(p.join(vendor.path, '..', 'PubCache.swift')),
      ].join('\r\n');
      expect(await repair(output), isTrue);
      expect(reported.readAsStringSync(), contains('@_XcrossSwiftUIState'));
      expect(staged.readAsStringSync(), contains('@_XcrossSwiftUIState'));
      expect(unreported.readAsStringSync(), original);
      expect(outside.readAsStringSync(), original);
      expect(siblingFile.readAsStringSync(), original);
      expect(await repair(output), isFalse);
    });

    test('ignores near-match diagnostics and symlink escapes', () async {
      final file = source(p.join(vendor.path, 'View.swift'));
      final original = file.readAsStringSync();
      for (final output in [
        diagnostic(file.path).replaceAll('StateMacro', 'OtherMacro'),
        diagnostic(file.path).replaceAll('error:', 'warning:'),
        diagnostic(file.path).replaceAll(
          "plugin for module 'SwiftUIMacros' not found",
          'different error',
        ),
        diagnostic('View.swift'),
      ]) {
        expect(await repair(output), isFalse);
      }
      expect(file.readAsStringSync(), original);
      final outside = source(p.join(root.path, 'External.swift'));
      final link = Link(p.join(vendor.path, 'Linked.swift'));
      try {
        link.createSync(outside.path);
      } on FileSystemException {
        markTestSkipped('host cannot create symlink boundary fixture');
        return;
      }
      expect(await repair(diagnostic(link.path)), isFalse);
      expect(outside.readAsStringSync(), original);
    });

    test(
      'retries once only after a source change and propagates next error',
      () async {
        final file = source(p.join(vendor.path, 'View.swift'));
        var calls = 0;
        final nextFile = source(p.join(vendor.path, 'Next.swift'));
        final nextOriginal = nextFile.readAsStringSync();
        final secondError = StateError('\n${diagnostic(nextFile.path)}');
        await expectLater(
          GeneratedPluginsPackage.buildWithSwiftUIStateRecovery(
            ownedRoots: [vendor.path],
            build: () {
              calls++;
              if (calls == 1) throw StateError('\n${diagnostic(file.path)}');
              throw secondError;
            },
          ),
          throwsA(same(secondError)),
        );
        expect(calls, 2);
        expect(nextFile.readAsStringSync(), nextOriginal);
        calls = 0;
        final unchanged = StateError('\n${diagnostic(file.path)}');
        await expectLater(
          GeneratedPluginsPackage.buildWithSwiftUIStateRecovery(
            ownedRoots: [vendor.path],
            build: () {
              calls++;
              throw unchanged;
            },
          ),
          throwsA(same(unchanged)),
        );
        expect(calls, 1);
      },
    );

    test(
      'successful repair retries successfully; unrelated error is preserved',
      () async {
        final file = source(p.join(vendor.path, 'View.swift'));
        var calls = 0;
        await GeneratedPluginsPackage.buildWithSwiftUIStateRecovery(
          ownedRoots: [vendor.path],
          build: () async {
            calls++;
            if (calls == 1) throw StateError('\n${diagnostic(file.path)}');
          },
        );
        expect(calls, 2);
        final error = StateError('ordinary failure');
        calls = 0;
        await expectLater(
          GeneratedPluginsPackage.buildWithSwiftUIStateRecovery(
            ownedRoots: [vendor.path],
            build: () {
              calls++;
              throw error;
            },
          ),
          throwsA(same(error)),
        );
        expect(calls, 1);
      },
    );
    test('atomic repair does not mutate an external hardlink peer', () async {
      final external = source(p.join(root.path, 'PubCache.swift'));
      final original = external.readAsStringSync();
      final staged = File(p.join(vendor.path, 'Hardlink.swift'));
      final link = Platform.isWindows
          ? await Process.run('fsutil', [
              'hardlink',
              'create',
              staged.path,
              external.path,
            ])
          : await Process.run('ln', [external.path, staged.path]);
      expect(link.exitCode, 0, reason: '${link.stdout}${link.stderr}');
      expect(
        FileSystemEntity.identicalSync(staged.path, external.path),
        isTrue,
      );
      expect(await repair(diagnostic(staged.path)), isTrue);
      expect(external.readAsStringSync(), original);
      expect(staged.readAsStringSync(), contains('@_XcrossSwiftUIState'));
      expect(
        FileSystemEntity.identicalSync(staged.path, external.path),
        isFalse,
      );
    });

    test(
      'failed repair preserves original compiler error without retry',
      () async {
        final invalid = File(p.join(vendor.path, 'Invalid.swift'))
          ..writeAsBytesSync([0xff]);
        final error = StateError('\n${diagnostic(invalid.path)}');
        var calls = 0;
        await expectLater(
          GeneratedPluginsPackage.buildWithSwiftUIStateRecovery(
            ownedRoots: [vendor.path],
            build: () {
              calls++;
              throw error;
            },
          ),
          throwsA(same(error)),
        );
        expect(calls, 1);
        expect(invalid.readAsBytesSync(), [0xff]);
      },
    );
  });
}
