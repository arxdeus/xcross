import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';
import 'package:xcross/src/shared/sdk/swift_environment_host.dart';

import 'swiftpm_test_context.dart';

final _swiftPmRuntime = testSwiftPmRuntime();
final _windowsRuntime = testWindowsSwiftPmRuntime();

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('xcross-cross-host-'));
  tearDown(() => root.deleteSync(recursive: true));

  test('passes the resolved host Swift environment to SwiftPM', () async {
    final environment = RecordingSwiftEnvironment(
      () async => {'SDKROOT': r'C:\Swift\Windows.sdk'},
    );
    final runtime = testWindowsSwiftPmRuntime(swiftEnvironment: environment);
    final resolved = await runtime.processPolicy.swiftProcessEnvironment();
    expect(resolved['SDKROOT'], r'C:\Swift\Windows.sdk');
    expect(resolved['EXPERIMENTAL_SPM_BUILDS'], '1');
    expect(resolved['GIT_TERMINAL_PROMPT'], '0');
    expect(runtime.processPolicy.sourceFallbackActive, isTrue);
    expect(environment.calls, 1);
  });

  test('stops before SwiftPM when the host Swift environment fails', () async {
    final runtime = testWindowsSwiftPmRuntime(
      swiftEnvironment: RecordingSwiftEnvironment(
        () async => throw XcrossError('SDKROOT is not set'),
      ),
    );
    await expectLater(
      runtime.processPolicy.swiftProcessEnvironment(),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          'SDKROOT is not set',
        ),
      ),
    );
  });

  test('prefers bundled xcrun using the Windows PATH list separator', () async {
    File(p.join(root.path, 'xcrun.exe')).writeAsStringSync('tool');
    final executable = p.join(root.path, 'xcross.exe');
    Future<Map<String, String>> environment(
      String path,
      SwiftPmRuntime runtime,
    ) => runtime.processPolicy.swiftProcessEnvironment(
      executable: executable,
      environment: {'PATH': path},
    );
    expect(
      (await environment('other;tools', _windowsRuntime))['PATH'],
      '${root.path};other;tools',
    );
    expect((await environment('', _windowsRuntime))['PATH'], root.path);
    expect(
      await environment('other:tools', _swiftPmRuntime),
      isNot(contains('PATH')),
    );
    File(p.join(root.path, 'xcrun.exe')).deleteSync();
    expect(
      await environment('other;tools', _windowsRuntime),
      isNot(contains('PATH')),
    );
  });

  for (final runtime in <SwiftPmRuntime<PlatformHostInterface>>[
    _swiftPmRuntime,
    _windowsRuntime,
  ]) {
    test(
      'recovers reachable internal headers after a failed aggregate (${runtime.host.name})',
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
        await testGenericInteropRecovery(
          runtime,
          RecordingSwiftPmInteropBuild(
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
          ),
        ).build(
          targetBuildDir: root.path,
          interopTargetCandidates: const {'Public'},
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
      testWindowsInteropRecovery(
        _windowsRuntime,
        RecordingSwiftPmInteropBuild(
          build: () {
            builds++;
            return Future<void>.error(originalError);
          },
          buildTarget: (_) async => throw targetError,
        ),
      ).build(targetBuildDir: root.path, interopTargetCandidates: const {}),
      throwsA(same(originalError)),
    );
    expect(builds, 1);
  });
}

@internal
final class RecordingSwiftEnvironment implements SwiftEnvironmentHostInterface {
  RecordingSwiftEnvironment(this.resolve);
  final Future<Map<String, String>> Function() resolve;
  int calls = 0;
  @override
  Future<Map<String, String>> swiftEnvironment() {
    calls++;
    return resolve();
  }

  @override
  Future<List<DoctorCheck>> doctorChecks() async => const [];
}
