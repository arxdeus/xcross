// Exercises the arm64e.x1 rewrite through the paths a real install takes:
// a cpio stream into SdkInstall.writeSdkEntries, and DarwinSdk.current's
// repair of a bundle installed before the rewrite existed.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/sdk_command.dart';

import '../../../darwin_sdk_kit/test/test_fixtures.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_sdk_tbd-');
  });

  tearDown(() => tmp.delete(recursive: true));

  const sdkRelative =
      'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk';

  String stub(String targets) =>
      '--- !tapi-tbd\n'
      'tbd-version:     4\n'
      'targets:         [ $targets ]\n'
      "install-name:    '/usr/lib/libSystem.dylib'\n";

  CpioEntry entry(
    String name, {
    int mode = 0x81a4,
    String data = '',
    int dev = 0,
    int ino = 0,
    int nlink = 1,
  }) => CpioEntry(
    name: name,
    mode: mode,
    data: Uint8List.fromList(utf8.encode(data)),
    dev: dev,
    ino: ino,
    nlink: nlink,
  );

  test('rewrites text stubs as the SDK is extracted', () async {
    final written = await SdkInstall.writeSdkEntries(
      Stream.fromIterable([
        entry(
          'Xcode.app/Contents/$sdkRelative/usr/lib/libSystem.tbd',
          data: stub('arm64e-ios, arm64e.x1-ios'),
        ),
        entry(
          'Xcode.app/Contents/$sdkRelative/usr/lib/libOther.tbd',
          data: stub('arm64-ios, arm64e-ios'),
        ),
        entry(
          'Xcode.app/Contents/$sdkRelative/usr/include/notes.txt',
          data: 'arm64e.x1-ios',
        ),
      ]),
      tmp.path,
    );

    expect(written, 3);
    String read(String relative) => File(
      p.join(tmp.path, p.joinAll(relative.split('/'))),
    ).readAsStringSync();

    expect(read('$sdkRelative/usr/lib/libSystem.tbd'), isNot(contains('.x1')));
    expect(
      read('$sdkRelative/usr/lib/libOther.tbd'),
      stub('arm64-ios, arm64e-ios'),
    );
    // Only text stubs are rewritten; nothing else in the SDK is touched.
    expect(read('$sdkRelative/usr/include/notes.txt'), 'arm64e.x1-ios');
    // Stamped, so resolving the bundle later does not rescan it.
    expect(TbdBundlePatch.isStamped(tmp.path), isTrue);
  });

  test('rewrites every member of a cpio hard-link group', () async {
    // cpio ships a hard link's bytes once; the later entries are empty and
    // replay the first payload. Rewriting at write time has to see the
    // replayed bytes, or the second copy keeps the unparsable target.
    final archive = BytesBuilder()
      ..add(
        buildCpioEntry(
          name: 'Xcode.app/Contents/$sdkRelative/usr/lib/libFirst.tbd',
          data: utf8.encode(stub('arm64e-ios, arm64e.x1-ios')),
          dev: 1,
          ino: 7,
          nlink: 2,
        ),
      )
      ..add(
        buildCpioEntry(
          name: 'Xcode.app/Contents/$sdkRelative/usr/lib/libSecond.tbd',
          data: const [],
          dev: 1,
          ino: 7,
          nlink: 2,
        ),
      )
      ..add(buildCpioTrailer());

    await SdkInstall.writeSdkEntries(
      CpioReader.read(Stream.value(archive.takeBytes())),
      tmp.path,
    );

    for (final name in ['libFirst.tbd', 'libSecond.tbd']) {
      final path = p.join(
        tmp.path,
        p.joinAll('$sdkRelative/usr/lib/$name'.split('/')),
      );
      expect(
        File(path).readAsStringSync(),
        stub('arm64e-ios, arm64e-ios'),
        reason: '$name should have been rewritten',
      );
    }
  });

  test('materialized symlink copies inherit the rewrite', () async {
    await SdkInstall.writeSdkEntries(
      Stream.fromIterable([
        entry(
          'Xcode.app/Contents/$sdkRelative/usr/lib/libReal.tbd',
          data: stub('arm64e.x1-ios'),
        ),
        entry(
          'Xcode.app/Contents/$sdkRelative/usr/lib/libAlias.tbd',
          mode: 0xa1ff,
          data: 'libReal.tbd',
        ),
      ]),
      tmp.path,
      materializeLinks: true,
    );

    final alias = File(
      p.join(
        tmp.path,
        p.joinAll('$sdkRelative/usr/lib/libAlias.tbd'.split('/')),
      ),
    );
    expect(alias.readAsStringSync(), stub('arm64e-ios'));
  });

  test('repairs a bundle installed before the rewrite existed', () async {
    // A complete bundle, as an older xcross would have left it: valid, but
    // with stubs no released ld64.lld can parse and no rewrite stamp.
    final bundle = p.join(tmp.path, 'xcross-darwin.artifactbundle');
    for (final name in ['info.json', 'swift-sdk.json', 'toolset.json']) {
      await File(p.join(bundle, name)).create(recursive: true);
      await File(p.join(bundle, name)).writeAsString('{}');
    }
    final sdkRoot = p.join(bundle, p.joinAll(sdkRelative.split('/')));
    await Directory(
      p.join(sdkRoot, 'System', 'Library', 'Frameworks'),
    ).create(recursive: true);
    for (final layout in [
      p.join(
        bundle,
        'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos',
      ),
      p.join(bundle, 'Developer/Runtimes/XcodeDefault.xctoolchain/usr/bin'),
    ]) {
      final file = File(p.join(layout, 'layouts-arm64.yaml'));
      await file.create(recursive: true);
      await file.writeAsString('layout');
    }
    final stubFile = File(p.join(sdkRoot, 'usr', 'lib', 'libSystem.tbd'));
    await stubFile.create(recursive: true);
    await stubFile.writeAsString(stub('arm64e-ios, arm64e.x1-ios'));

    expect(DarwinSdk.isValidBundle(bundle), isTrue);
    expect(TbdBundlePatch.isStamped(bundle), isFalse);

    final sdk = DarwinSdk.current(bundle: bundle);

    expect(sdk, isNotNull);
    expect(stubFile.readAsStringSync(), isNot(contains('.x1')));
    expect(TbdBundlePatch.isStamped(bundle), isTrue);

    // Second resolve is a stamp read, not another tree scan: re-adding an
    // unparsable stub must not be undone behind the user's back.
    await stubFile.writeAsString(stub('arm64e.x1-ios'));
    DarwinSdk.current(bundle: bundle);
    expect(stubFile.readAsStringSync(), contains('.x1'));
  });
}
