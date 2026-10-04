import 'dart:async';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/linux/update/linux_update_policy.dart';
import 'package:xcross/src/host/macos/update/macos_update_policy.dart';
import 'package:xcross/src/host/windows/update/windows_update_policy.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/update/install_layout.dart';
import 'package:xcross/src/shared/update/self_update.dart';
import 'package:xcross/src/shared/update/update_check.dart';
import 'package:xcross/src/shared/update/update_progress.dart';

import '../host_operations_fixtures.dart';
import 'file_swap_fixtures.dart';

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
  test(
    'release matrix preserves Linux and Windows x64 and arm64',
    () {
      for (final architecture in ['x64', 'arm64']) {
        final host = LinuxHost(architecture: architecture);
        expect(
          LinuxUpdatePolicy(
            host,
            fixtureRunner(host, log: fixtureLog()),
            FixturePrivileges(),
          ).releaseAsset(),
          'xcross-linux-$architecture.tar.gz',
        );
        expect(
          WindowsUpdatePolicy(
            WindowsHost(architecture: architecture),
            FixturePrivileges(),
          ).releaseAsset(),
          'xcross-windows-$architecture.zip',
        );
      }
      for (final architecture in ['ia32', 'arm', 'unknown']) {
        expect(
          () => WindowsUpdatePolicy(
            WindowsHost(architecture: architecture),
            FixturePrivileges(),
          ).releaseAsset(),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.toString(),
              'message',
              contains('windows/$architecture'),
            ),
          ),
        );
      }
      final mac = MacOSHost(architecture: 'arm64');
      expect(
        () => MacOSUpdatePolicy(
          mac,
          fixtureRunner(mac, log: fixtureLog()),
          FixturePrivileges(),
        ).releaseAsset(),
        throwsA(isA<XcrossError>()),
      );
      final linux = LinuxHost();
      expect(
        () => LinuxUpdatePolicy(
          linux,
          fixtureRunner(linux, log: fixtureLog()),
          FixturePrivileges(),
        ).releaseAsset(),
        throwsA(isA<XcrossError>()),
      );
    },
  );

  late SelfUpdate updater;
  late Directory root;
  late Directory prefix;
  late Directory bundle;
  late InstallLayout layout;
  late List<_RunRequest> runRequests;

  File installedBin(String contents) =>
      File(p.join(prefix.path, 'bin', _exeName()))..writeAsStringSync(contents);

  File installedLib(String name, String contents) =>
      File(p.join(prefix.path, 'lib', name))..writeAsStringSync(contents);

  File bundleBin(String contents) {
    final bin = File(p.join(bundle.path, 'bin', _exeName()))
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
    File(
      p.join(bundle.path, 'bin', Platform.isWindows ? 'xcrun.exe' : 'xcrun'),
    ).writeAsStringSync('xcrun');
    return bin;
  }

  File bundleLib(String name, String contents) =>
      File(p.join(bundle.path, 'lib', name))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);

  setUp(() {
    final host = LinuxHost();
    final runner = fixtureRunner(host, log: fixtureLog());
    updater = SelfUpdate(
      host: host,
      runner: runner,
      downloader: Downloader(
        createClient: () => throw StateError('unexpected download'),
        log: runner.log,
      ),
      policy: LinuxUpdatePolicy(host, runner, FixturePrivileges()),
    );
    root = Directory.systemTemp.createTempSync('xcross-self-update-');
    prefix = Directory(p.join(root.path, 'install'));
    Directory(p.join(prefix.path, 'bin')).createSync(recursive: true);
    Directory(p.join(prefix.path, 'lib')).createSync(recursive: true);
    bundle = Directory(p.join(root.path, 'bundle'))..createSync();
    layout = InstallLayout(
      host: host,
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

  test(
    'verification failure restores remapped installed executable and libraries',
    () async {
      final mapped = FixtureRemappedOperations(root);
      mapped.file('/logical/bin/xcross').writeAsStringSync('old xcross');
      mapped.file('/logical/bin/xcrun').writeAsStringSync('old xcrun');
      mapped.file('/logical/lib/fixture.so').writeAsStringSync('old library');
      bundleBin('new xcross');
      bundleLib('fixture.so', 'new library');
      final host = LinuxHost(fileSystem: FixtureMappedFileSystem(root));
      final runner = fixtureRunner(host, log: fixtureLog());
      final updater = SelfUpdate(
        host: host,
        runner: runner,
        policy: LinuxUpdatePolicy(host, runner, FixturePrivileges()),
        downloader: Downloader(
          createClient: () => throw StateError('unexpected download'),
          log: runner.log,
        ),
      );
      final layout = InstallLayout(
        host: host,
        binaryPath: '/logical/bin/xcross',
        binDir: '/logical/bin',
        libDir: '/logical/lib',
      );
      await expectLater(
        _installBundle(
          updater,
          bundleRoot: bundle,
          layout: layout,
          label: 'fixture',
          runProcess:
              ({
                required executable,
                required arguments,
                required environment,
                required timeout,
              }) async =>
                  const CapturedProcess(37, '', 'fixture verification denied'),
        ),
        throwsA(isA<XcrossError>()),
      );
      expect(
        mapped.file('/logical/bin/xcross').readAsStringSync(),
        'old xcross',
      );
      expect(mapped.file('/logical/bin/xcrun').readAsStringSync(), 'old xcrun');
      expect(
        mapped.file('/logical/lib/fixture.so').readAsStringSync(),
        'old library',
      );
    },
  );

  test('consumes the final source install and verify phases', () async {
    bundleBin('new-bin');
    bundleLib('libkeep.so', 'new-lib');

    final progress = UpdateProgress('Source', 7, log: fixtureLog());
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
      await _installBundle(
        updater,
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

    await _installBundle(
      updater,
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
    expect(
      runRequests.single.environment,
      containsPair(SelfUpdate.verificationEnvVar, '1'),
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
      _installBundle(
        updater,
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

    await _installBundle(
      updater,
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

    expect(
      Directory(
        layout.binDir,
      ).listSync().map((e) => p.basename(e.path)).toSet(),
      {_exeName(), if (Platform.isWindows) 'xcrun.exe' else 'xcrun'},
    );

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
        _verifyInstalledBinary(
          updater,
          layout: layout,
          label: 'xcross 1.2.3',
          expectedIdentity: 'v1.2.3',
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

  test('release verification normalizes a v-prefixed tag', () async {
    await _verifyInstalledBinary(
      updater,
      layout: layout,
      label: 'xcross v1.2.3',
      expectedIdentity: 'v1.2.3',
      expectedReleased: true,
      runProcess:
          ({
            required executable,
            required arguments,
            required environment,
            required timeout,
          }) async => const CapturedProcess(0, 'xcross 1.2.3\n', ''),
    );
  });

  test('detects the self-update verification process', () {
    expect(SelfUpdate.isVerificationProcess({}), isFalse);
    expect(
      SelfUpdate.isVerificationProcess({SelfUpdate.verificationEnvVar: '1'}),
      isTrue,
    );
  });

  test('source verification requires the exact arbitrary identity', () async {
    await _verifyInstalledBinary(
      updater,
      layout: layout,
      label: 'xcross main',
      expectedIdentity: 'main',
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
      _verifyInstalledBinary(
        updater,
        layout: layout,
        label: 'xcross main',
        expectedIdentity: 'main',
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
      _verifyInstalledBinary(
        updater,
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
      _installBundle(
        updater,
        bundleRoot: bundle,
        layout: layout,
        label: 'xcross main',
        expectedIdentity: 'main',
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
      _installBundle(
        updater,
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

SelfUpdate _configuredUpdater(
  SelfUpdate updater,
  UpdateVerificationProcess? verifyProcess,
) => SelfUpdate(
  host: updater.host,
  runner: updater.runner,
  policy: updater.policy,
  downloader: updater.downloader,
  verifyProcess: verifyProcess,
);

Future<CapturedProcess> _verifyInstalledBinary(
  SelfUpdate updater, {
  required InstallLayout layout,
  required String label,
  String? expectedIdentity,
  bool expectedReleased = false,
  UpdateProgress? progress,
  UpdateVerificationProcess? runProcess,
}) => _configuredUpdater(updater, runProcess).verifyInstalledBinary(
  layout: layout,
  label: label,
  expectedIdentity: expectedIdentity,
  expectedReleased: expectedReleased,
  progress: progress,
);

Future<void> _installBundle(
  SelfUpdate updater, {
  required Directory bundleRoot,
  required InstallLayout layout,
  required String label,
  String? expectedIdentity,
  bool expectedReleased = false,
  UpdateProgress? progress,
  UpdateVerificationProcess? runProcess,
}) => _configuredUpdater(updater, runProcess).installBundle(
  bundleRoot: bundleRoot,
  layout: layout,
  label: label,
  expectedIdentity: expectedIdentity,
  expectedReleased: expectedReleased,
  progress: progress,
);
