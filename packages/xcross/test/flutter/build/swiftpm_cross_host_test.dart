import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('xcross-cross-host-'));
  tearDown(() => root.deleteSync(recursive: true));

  test('prefers bundled xcrun using the Windows PATH list separator', () {
    File(p.join(root.path, 'xcrun.exe')).writeAsStringSync('tool');
    final executable = p.join(root.path, 'xcross.exe');
    Map<String, String> environment(String path, {required bool windows}) =>
        GeneratedPluginsPackage.swiftProcessEnvironment(
          windows: windows,
          executable: executable,
          environment: {'PATH': path},
        )!;
    expect(
      environment('other;tools', windows: true)['PATH'],
      '${root.path};other;tools',
    );
    expect(environment('', windows: true)['PATH'], root.path);
    expect(environment('other:tools', windows: false), isNot(contains('PATH')));
    File(p.join(root.path, 'xcrun.exe')).deleteSync();
    expect(environment('other;tools', windows: true), isNot(contains('PATH')));
  });

  for (final windows in [false, true]) {
    test(
      'recovers reachable internal headers after a failed aggregate ($windows)',
      () async {
        final include = p.join(root.path, 'Internal.build', 'include');
        Directory(include).createSync(recursive: true);
        File(
          p.join(include, 'module.modulemap'),
        ).writeAsStringSync('module Internal { header "Internal-Swift.h" }');
        final excluded = p.join(root.path, 'Unused.build', 'include');
        Directory(excluded).createSync(recursive: true);
        File(
          p.join(excluded, 'module.modulemap'),
        ).writeAsStringSync('module Unused { header "Unused-Swift.h" }');
        File(p.join(root.path, 'description.json')).writeAsStringSync(
          jsonEncode({
            'swiftCommands': <String, Object?>{},
            'targetDependencyMap': {
              'FlutterPluginsGenerated': ['Public'],
              'Public': ['Internal'],
              'Internal': <String>[],
              'Unused': <String>[],
            },
          }),
        );
        final events = <String>[];
        var attempts = 0;
        await GeneratedPluginsPackage.buildWithInteropRecovery(
          targetBuildDir: root.path,
          interopTargetCandidates: const {'Public'},
          windows: windows,
          build: () async {
            events.add('build');
            if (++attempts == 1) {
              throw StateError("'Internal-Swift.h' file not found");
            }
          },
          buildTarget: (target) async {
            events.add(target);
            File(
              p.join(include, '$target-Swift.h'),
            ).writeAsStringSync('// header');
          },
        );
        expect(events, ['build', 'Internal', 'build']);
      },
    );
  }

  test('does not hide errors from an internal target build', () async {
    final include = p.join(root.path, 'Internal.build', 'include');
    Directory(include).createSync(recursive: true);
    File(
      p.join(include, 'module.modulemap'),
    ).writeAsStringSync('module Internal { header "Internal-Swift.h" }');
    File(p.join(root.path, 'description.json')).writeAsStringSync(
      jsonEncode({
        'targetDependencyMap': {
          'FlutterPluginsGenerated': ['Internal'],
          'Internal': <String>[],
        },
      }),
    );
    final targetError = StateError('target compilation failed');
    final originalError = StateError("'Internal-Swift.h' file not found");
    var builds = 0;
    await expectLater(
      GeneratedPluginsPackage.buildWithInteropRecovery(
        targetBuildDir: root.path,
        interopTargetCandidates: const {},
        windows: true,
        build: () {
          builds++;
          return Future<void>.error(originalError);
        },
        buildTarget: (_) async => throw targetError,
      ),
      throwsA(same(originalError)),
    );
    expect(builds, 1);
  });
}
