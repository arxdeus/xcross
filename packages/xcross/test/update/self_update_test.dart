import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/install_layout.dart';
import 'package:xcross/src/update/self_update.dart';
import 'package:xcross/src/update/semver.dart';

String _exeName() => Platform.isWindows ? 'xcross.exe' : 'xcross';

void main() {
  late Directory root;
  late Directory prefix;
  late Directory bundle;
  late InstallLayout layout;

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
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('source bundle install swaps bin and lib payloads', () async {
    installedBin('old-bin');
    installedLib('libkeep.so', 'old-lib');
    bundleBin('new-bin');
    bundleLib('libkeep.so', 'new-lib');

    await SelfUpdate.installBundle(
      bundleRoot: bundle,
      layout: layout,
      label: 'source build',
      verifyInstalledBinary:
          ({required layout, required expectedVersion}) async =>
              const CapturedProcess(0, 'xcross 9.9.9-dev', ''),
    );

    expect(File(layout.binaryPath).readAsStringSync(), 'new-bin');
    expect(File(p.join(layout.libDir, 'libkeep.so')).readAsStringSync(), 'new-lib');
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
        verifyInstalledBinary:
            ({required layout, required expectedVersion}) async =>
                throw XcrossError('verification failed'),
      ),
      throwsA(isA<XcrossError>()),
    );

    expect(File(layout.binaryPath).readAsStringSync(), 'old-bin');
    expect(File(p.join(layout.libDir, 'libkeep.so')).readAsStringSync(), 'old-lib');
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
      verifyInstalledBinary:
          ({required layout, required expectedVersion}) async =>
              const CapturedProcess(0, 'xcross 1.2.3-dev', ''),
    );

    expect(
      Directory(layout.binDir).listSync().map((e) => p.basename(e.path)),
      [_exeName()],
    );
    expect(
      Directory(layout.libDir).listSync().map((e) => p.basename(e.path)).toSet(),
      {'libkeep.so'},
    );
  });

  test('release verification still requires the expected tag version', () async {
    await expectLater(
      SelfUpdate.verifyInstalledBinary(
        layout: layout,
        label: 'xcross 1.2.3',
        expectedVersion: XcrossSemver.tryParse('1.2.3'),
        runProcess:
            ({required executable,
            required arguments,
            required environment,
            required timeout}) async => const CapturedProcess(
              0,
              'xcross credits banner xcross 1.2.4',
              '',
            ),
      ),
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('did not report version 1.2.3'),
        ),
      ),
    );
  });

  test('source verification accepts a dev semver', () async {
    await SelfUpdate.verifyInstalledBinary(
      layout: layout,
      label: 'source build',
      runProcess:
          ({required executable,
          required arguments,
          required environment,
          required timeout}) async => const CapturedProcess(
            0,
            'xcross credits banner\nxcross 2.0.0-dev+abc123',
            '',
          ),
    );
  });

  test('source verification rejects failed or versionless output', () async {
    Future<void> expectInvalid(CapturedProcess result) => expectLater(
      SelfUpdate.verifyInstalledBinary(
        layout: layout,
        label: 'source build',
        runProcess:
            ({required executable,
            required arguments,
            required environment,
            required timeout}) async => result,
      ),
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('did not report a parseable xcross version'),
        ),
      ),
    );

    await expectInvalid(const CapturedProcess(1, 'xcross 2.0.0-dev', 'boom'));
    await expectInvalid(const CapturedProcess(0, 'xcross build from source', ''));
  });
}
