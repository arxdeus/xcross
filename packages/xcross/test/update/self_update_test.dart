import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/install_layout.dart';
import 'package:xcross/src/update/self_update.dart';
import 'package:xcross/src/update/update_check.dart';
import 'package:xcross/src/update/update_progress.dart';

String _exeName() => Platform.isWindows ? 'xcross.exe' : 'xcross';

Future<List<String>> _captureAsync(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, __, ___, line) => lines.add(line),
    ),
  );
  return lines;
}

typedef _RunRequest = ({
  String executable,
  List<String> arguments,
  Map<String, String> environment,
  Duration timeout,
});

void main() {
  late Directory root;
  late Directory prefix;
  late Directory bundle;
  late InstallLayout layout;
  late List<_RunRequest> runRequests;

  File installedBin(String contents) =>
      File(p.join(prefix.path, 'bin', _exeName()))..writeAsStringSync(contents);

  File installedLib(String name, String contents) =>
      File(p.join(prefix.path, 'lib', name))..writeAsStringSync(contents);

  File bundleBin(String contents) =>
      File(p.join(bundle.path, 'bin', _exeName()))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);

  File bundleLib(String name, String contents) =>
      File(p.join(bundle.path, 'lib', name))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);

  setUp(() {
    root = Directory.systemTemp.createTempSync('xcross-self-update-');
    prefix = Directory(p.join(root.path, 'install'));
    Directory(p.join(prefix.path, 'bin')).createSync(recursive: true);
    Directory(p.join(prefix.path, 'lib')).createSync(recursive: true);
    bundle = Directory(p.join(root.path, 'bundle'))..createSync();
    layout = InstallLayout(
      binaryPath: p.join(prefix.path, 'bin', _exeName()),
      binDir: p.join(prefix.path, 'bin'),
      libDir: p.join(prefix.path, 'lib'),
    );
    runRequests = [];
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<CapturedProcess> recordRun({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required Duration timeout,
    required CapturedProcess result,
  }) async {
    runRequests.add((
      executable: executable,
      arguments: arguments,
      environment: environment,
      timeout: timeout,
    ));
    return result;
  }

  test('consumes the final source install and verify phases', () async {
    bundleBin('new-bin');
    bundleLib('libkeep.so', 'new-lib');

    final progress = UpdateProgress('Source', 7);
    for (final action in const [
      'Clone repository',
      'Fetch commit',
      'Check out commit',
      'Resolve dependencies',
      'Build xcross main',
    ]) {
      progress.nextLabel(action);
    }

    final lines = await _captureAsync(() async {
      await SelfUpdate.installBundle(
        bundleRoot: bundle,
        layout: layout,
        label: 'xcross main',
        expectedIdentity: 'main',
        progress: progress,
        runProcess:
            ({
              required executable,
              required arguments,
              required environment,
              required timeout,
            }) => recordRun(
              executable: executable,
              arguments: arguments,
              environment: environment,
              timeout: timeout,
              result: const CapturedProcess(
                0,
                'xcross main (unreleased build)\n',
                '',
              ),
            ),
      );
    });

    expect(
      lines.where((line) => line.contains('Source [')),
      containsAllInOrder([
        contains('[6/7] Install xcross main'),
        contains('[7/7] Verify xcross main'),
      ]),
    );
  });

  test('source bundle install swaps bin and lib payloads', () async {
    installedBin('old-bin');
    installedLib('libkeep.so', 'old-lib');
    bundleBin('new-bin');
    bundleLib('libkeep.so', 'new-lib');

    await SelfUpdate.installBundle(
      bundleRoot: bundle,
      layout: layout,
      label: 'source build',
      runProcess:
          ({
            required executable,
            required arguments,
            required environment,
            required timeout,
          }) => recordRun(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            result: const CapturedProcess(
              0,
              'xcross main (unreleased build)\n',
              '',
            ),
          ),
    );

    expect(File(layout.binaryPath).readAsStringSync(), 'new-bin');
    expect(
      File(p.join(layout.libDir, 'libkeep.so')).readAsStringSync(),
      'new-lib',
    );
    expect(runRequests, hasLength(1));
    expect(runRequests.single.executable, layout.binaryPath);
    expect(runRequests.single.arguments, const ['--version']);
    expect(
      runRequests.single.environment,
      containsPair(UpdateCheck.disableEnvVar, '1'),
    );
    expect(runRequests.single.timeout, const Duration(seconds: 30));
  });

  test('verification failure rolls back all swapped files', () async {
    installedBin('old-bin');
    installedLib('libkeep.so', 'old-lib');
    bundleBin('new-bin');
    bundleLib('libkeep.so', 'new-lib');
    bundleLib('libnew.so', 'fresh-lib');

    await expectLater(
      SelfUpdate.installBundle(
        bundleRoot: bundle,
        layout: layout,
        label: 'source build',
        runProcess:
            ({
              required executable,
              required arguments,
              required environment,
              required timeout,
            }) => recordRun(
              executable: executable,
              arguments: arguments,
              environment: environment,
              timeout: timeout,
              result: const CapturedProcess(
                1,
                'xcross other (unreleased build)\n',
                'boom',
              ),
            ),
      ),
      throwsA(isA<XcrossError>()),
    );

    expect(File(layout.binaryPath).readAsStringSync(), 'old-bin');
    expect(
      File(p.join(layout.libDir, 'libkeep.so')).readAsStringSync(),
      'old-lib',
    );
    expect(File(p.join(layout.libDir, 'libnew.so')).existsSync(), isFalse);
  });

  test('successful verification discards backups', () async {
    installedBin('old-bin');
    installedLib('libkeep.so', 'old-lib');
    bundleBin('new-bin');
    bundleLib('libkeep.so', 'new-lib');

    await SelfUpdate.installBundle(
      bundleRoot: bundle,
      layout: layout,
      label: 'source build',
      runProcess:
          ({
            required executable,
            required arguments,
            required environment,
            required timeout,
          }) => recordRun(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            result: const CapturedProcess(
              0,
              'xcross main (unreleased build)\n',
              '',
            ),
          ),
    );

    expect(Directory(layout.binDir).listSync().map((e) => p.basename(e.path)), [
      _exeName(),
    ]);
    expect(
      Directory(
        layout.libDir,
      ).listSync().map((e) => p.basename(e.path)).toSet(),
      {'libkeep.so'},
    );
  });

  test(
    'release verification still requires the exact expected identity',
    () async {
      await expectLater(
        SelfUpdate.verifyInstalledBinary(
          layout: layout,
          label: 'xcross 1.2.3',
          expectedIdentity: '1.2.3',
          expectedReleased: true,
          runProcess:
              ({
                required executable,
                required arguments,
                required environment,
                required timeout,
              }) async => const CapturedProcess(
                0,
                'xcross credits banner\nxcross 1.2.4',
                '',
              ),
        ),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('did not report xcross 1.2.3'),
          ),
        ),
      );
    },
  );

  test('source verification requires the exact arbitrary identity', () async {
    await SelfUpdate.verifyInstalledBinary(
      layout: layout,
      label: 'xcross main',
      expectedIdentity: 'main',
      expectedReleased: false,
      runProcess:
          ({
            required executable,
            required arguments,
            required environment,
            required timeout,
          }) async =>
              const CapturedProcess(0, 'xcross main (unreleased build)\n', ''),
    );
  });

  test('source verification rejects a mismatched arbitrary identity', () async {
    await expectLater(
      SelfUpdate.verifyInstalledBinary(
        layout: layout,
        label: 'xcross main',
        expectedIdentity: 'main',
        expectedReleased: false,
        runProcess:
            ({
              required executable,
              required arguments,
              required environment,
              required timeout,
            }) async => const CapturedProcess(
              0,
              'xcross other (unreleased build)\n',
              '',
            ),
      ),
      throwsA(isA<XcrossError>()),
    );
  });

  test('source verification rejects a released marker mismatch', () async {
    await expectLater(
      SelfUpdate.verifyInstalledBinary(
        layout: layout,
        label: 'xcross 1.2.3',
        expectedIdentity: '1.2.3',
        expectedReleased: true,
        runProcess:
            ({
              required executable,
              required arguments,
              required environment,
              required timeout,
            }) async => const CapturedProcess(
              0,
              'xcross 1.2.3 (unreleased build)\n',
              '',
            ),
      ),
      throwsA(isA<XcrossError>()),
    );
  });

  test('installBundle rolls back on identity mismatch', () async {
    installedBin('old-bin');
    installedLib('libkeep.so', 'old-lib');
    bundleBin('new-bin');
    bundleLib('libkeep.so', 'new-lib');
    bundleLib('libnew.so', 'fresh-lib');

    await expectLater(
      SelfUpdate.installBundle(
        bundleRoot: bundle,
        layout: layout,
        label: 'xcross main',
        expectedIdentity: 'main',
        expectedReleased: false,
        runProcess:
            ({
              required executable,
              required arguments,
              required environment,
              required timeout,
            }) => recordRun(
              executable: executable,
              arguments: arguments,
              environment: environment,
              timeout: timeout,
              result: const CapturedProcess(
                0,
                'xcross other (unreleased build)\n',
                '',
              ),
            ),
      ),
      throwsA(isA<XcrossError>()),
    );

    expect(File(layout.binaryPath).readAsStringSync(), 'old-bin');
    expect(
      File(p.join(layout.libDir, 'libkeep.so')).readAsStringSync(),
      'old-lib',
    );
    expect(File(p.join(layout.libDir, 'libnew.so')).existsSync(), isFalse);
  });

  test('installBundle rolls back on release marker mismatch', () async {
    installedBin('old-bin');
    installedLib('libkeep.so', 'old-lib');
    bundleBin('new-bin');
    bundleLib('libkeep.so', 'new-lib');

    await expectLater(
      SelfUpdate.installBundle(
        bundleRoot: bundle,
        layout: layout,
        label: 'xcross 1.2.3',
        expectedIdentity: '1.2.3',
        expectedReleased: true,
        runProcess:
            ({
              required executable,
              required arguments,
              required environment,
              required timeout,
            }) => recordRun(
              executable: executable,
              arguments: arguments,
              environment: environment,
              timeout: timeout,
              result: const CapturedProcess(
                0,
                'xcross 1.2.3 (unreleased build)\n',
                '',
              ),
            ),
      ),
      throwsA(isA<XcrossError>()),
    );

    expect(File(layout.binaryPath).readAsStringSync(), 'old-bin');
    expect(
      File(p.join(layout.libDir, 'libkeep.so')).readAsStringSync(),
      'old-lib',
    );
  });
}
