import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_session.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_target_alias.dart';

import 'swiftpm_test_context.dart';

void main() {
  late Directory tmp;
  late String scratch;
  late String buildDir;
  late File manifest;
  final alias = SwiftPmManifestTargetAlias(
    fileSystem: testSwiftPmRuntime().artifactFileSystem,
  );
  const original = '''
client:
  name: basic
targets:
  "FlutterPluginsGenerated-arm64-apple-ios-debug.module": ["<FlutterPluginsGenerated-arm64-apple-ios-debug.module>"]
  "LeafAlpha-arm64-apple-ios-debug.module": ["<LeafAlpha-arm64-apple-ios-debug.module>"]
  "LeafBeta-arm64-apple-ios-debug.module": ["<LeafBeta-arm64-apple-ios-debug.module>"]
  "LeafGamma-arm64-apple-ios-debug.module": ["<LeafGamma-arm64-apple-ios-debug.module>"]
default: "main"
commands:
  "LeafAlpha-arm64-apple-ios-debug.module": ["ignored"]
''';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('manifest-target-alias-');
    scratch = tmp.path;
    buildDir = p.join(scratch, 'arm64-apple-ios', 'debug');
    manifest = File(p.join(scratch, 'debug.yaml'))..writeAsStringSync(original);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('builds several interop targets through one invocation', () async {
    String? during;
    final retained = await alias.withTargets(
      scratchPath: scratch,
      targetBuildDir: buildDir,
      target: 'LeafAlpha',
      extra: const ['LeafBeta', 'LeafGamma'],
      build: () async => during = manifest.readAsStringSync(),
    );

    expect(retained, isTrue);
    expect(
      during,
      contains(
        '"LeafAlpha-arm64-apple-ios-debug.module": '
        '["<LeafAlpha-arm64-apple-ios-debug.module>",'
        '"<LeafBeta-arm64-apple-ios-debug.module>",'
        '"<LeafGamma-arm64-apple-ios-debug.module>"]',
      ),
    );
    expect(manifest.readAsStringSync(), original);
  });

  test('reports a manifest replanned during the build', () async {
    final retained = await alias.withTargets(
      scratchPath: scratch,
      targetBuildDir: buildDir,
      target: 'LeafAlpha',
      extra: const ['LeafBeta'],
      build: () async => manifest.writeAsStringSync(original),
    );

    expect(retained, isFalse);
    expect(manifest.readAsStringSync(), original);
  });

  test('declines unknown targets without touching the manifest', () async {
    var built = false;
    final retained = await alias.withTargets(
      scratchPath: scratch,
      targetBuildDir: buildDir,
      target: 'LeafAlpha',
      extra: const ['Missing'],
      build: () async => built = true,
    );

    expect(retained, isNull);
    expect(built, isFalse);
    expect(manifest.readAsStringSync(), original);
  });

  test('restores the manifest when the build fails', () async {
    await expectLater(
      alias.withTargets(
        scratchPath: scratch,
        targetBuildDir: buildDir,
        target: 'LeafAlpha',
        extra: const ['LeafBeta'],
        build: () async => throw StateError('compile failed'),
      ),
      throwsStateError,
    );
    expect(manifest.readAsStringSync(), original);
  });

  test(
    'builds N interop targets with one warm-up and one swift build',
    () async {
      final runtime = testSwiftPmRuntime();
      final execution = RecordingAliasExecution(manifest);
      final session = SwiftPmBuildSession<MacOSHost>(
        execution: execution,
        command: SwiftPmBuildCommand(
          executable: 'swift',
          arguments: const ['build'],
          environment: const {},
          scratchPath: scratch,
          targetBuildDir: buildDir,
          consumerProducts: const {},
        ),
        consumerRepair: runtime.consumerRepair,
        targetAlias: alias,
      );

      await session.buildTargets(const ['LeafAlpha', 'LeafBeta', 'LeafGamma']);
      await session.buildTargets(const ['LeafBeta', 'LeafGamma']);

      expect(execution.invocations, [
        ['build', '--target', 'LeafAlpha'],
        ['build', '--target', 'LeafBeta'],
        ['build', '--target', 'LeafBeta'],
      ]);
      expect(execution.aliased, [
        ['LeafBeta', 'LeafGamma'],
        ['LeafBeta', 'LeafGamma'],
      ]);
      expect(manifest.readAsStringSync(), original);
    },
  );
}

@internal
final class RecordingAliasExecution
    implements SwiftPmBuildExecution<MacOSHost> {
  RecordingAliasExecution(this.manifest);
  final File manifest;
  final invocations = <List<String>>[];
  final aliased = <List<String>>[];
  @override
  Future<void> execute(SwiftPmBuildCommand command) async {
    invocations.add(command.arguments);
    final target = command.arguments.last;
    final line = manifest.readAsLinesSync().firstWhere(
      (line) => line.startsWith('  "$target-'),
    );
    final names = RegExp(
      '<([A-Za-z]+)-',
    ).allMatches(line).map((match) => match.group(1)!).toList();
    if (names.length > 1) aliased.add(names);
  }

  @override
  Future<void> recoverInterop({
    required Set<String> emitted,
    required SwiftPmBuildCommand command,
    required Object error,
    required StackTrace stack,
  }) => Future<void>.error(error, stack);
}
