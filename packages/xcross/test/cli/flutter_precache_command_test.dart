import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/flutter/subcommands/flutter_precache_command.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';

import '../log_fixture.dart';

void main() {
  Future<(List<String>, List<String>)> run(List<String> args) async {
    final calls = <String>[];
    final output = TestLogOutput();
    final command = FlutterPrecacheCommand(
      log: Log(output: output),
      resolveFlutterRoot: () async => '/flutter',
      precacheEngine: ({required flutterRoot, required mode}) async {
        calls.add('engine:${mode.name}:$flutterRoot');
      },
      precacheCompiler: ({required flutterRoot, required mode}) async {
        calls.add('compiler:${mode.name}');
        return (executable: '/cache/${mode.name}', source: 'downloaded');
      },
    );
    await (CommandRunner<void>(
      'xcross',
      'test',
    )..addCommand(command)).run(['precache', ...args]);
    return (calls, output.messages);
  }

  test('fetches every mode and both AOT compilers by default', () async {
    final (calls, lines) = await run([]);
    expect(calls, [
      'engine:debug:/flutter',
      'engine:profile:/flutter',
      'compiler:profile',
      'engine:release:/flutter',
      'compiler:release',
    ]);
    expect(lines, contains(contains('iOS AOT compiler (release): downloaded')));
  });

  test('debug needs no AOT compiler', () async {
    final (calls, _) = await run(['--mode', 'debug']);
    expect(calls, ['engine:debug:/flutter']);
  });

  test('a single precompiled mode fetches only its compiler', () async {
    final (calls, _) = await run(['--mode', 'release']);
    expect(calls, ['engine:release:/flutter', 'compiler:release']);
  });

  test('modes map to engine artifacts and compilers consistently', () {
    expect(FlutterBuildMode.release.engineArtifact, 'ios-release');
    expect(
      IosGenSnapshotMode.release.engineArtifact,
      FlutterBuildMode.release.engineArtifact,
    );
    expect(
      IosGenSnapshotMode.profile.engineArtifact,
      FlutterBuildMode.profile.engineArtifact,
    );
  });
}
