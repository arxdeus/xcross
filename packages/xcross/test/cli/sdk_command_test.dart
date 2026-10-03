import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/sdk_command.dart';
import 'package:xcross/src/errors.dart';

import '../../../darwin_sdk_kit/test/test_fixtures.dart';
import 'sdk_test_support.dart';

void main() {
  final installer = sdkFixtureInstaller();
  final materializedInstaller = sdkFixtureInstaller(
    links: MaterializedSdkArchiveLinks(sdkFixtureHost),
  );
  final publication = SdkInstallCommand(installer);
  group('SDK publication', () {
    late Directory root;

    void createValidBundle(String path) {
      for (final name in ['info.json', 'swift-sdk.json', 'toolset.json']) {
        File(p.join(path, name))
          ..createSync(recursive: true)
          ..writeAsStringSync('{}');
      }
      Directory(
        p.join(
          path,
          'Developer',
          'Platforms',
          'iPhoneOS.platform',
          'Developer',
          'SDKs',
          'iPhoneOS18.0.sdk',
          'System',
          'Library',
          'Frameworks',
        ),
      ).createSync(recursive: true);
      for (final location in [
        p.join(
          'Developer',
          'Toolchains',
          'XcodeDefault.xctoolchain',
          'usr',
          'lib',
          'swift',
          'iphoneos',
          'layouts-arm64.yaml',
        ),
        p.join(
          'Developer',
          'Runtimes',
          'XcodeDefault.xctoolchain',
          'usr',
          'bin',
          'layouts-arm64.yaml',
        ),
      ]) {
        File(p.join(path, location))
          ..createSync(recursive: true)
          ..writeAsStringSync('layout');
      }
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('xcross-sdk-publication-');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('replaces the old SDK only after staging succeeds', () async {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      final old = Directory(destination)..createSync();
      File(p.join(old.path, 'old.txt')).writeAsStringSync('old');
      if (Platform.isWindows) {
        final deepPath = p.joinAll([
          old.path,
          ...List.filled(6, 'nested-sdk-directory-with-long-name'),
        ]);
        expect(deepPath.length, greaterThan(260));
        Directory(installer.ioPath(deepPath)).createSync(recursive: true);
        File(
          installer.ioPath(p.join(deepPath, 'header.h')),
        ).writeAsStringSync('header');
      }
      final staged = Directory(p.join(root.path, 'Darwin.staging'))
        ..createSync();
      File(p.join(staged.path, 'new.txt')).writeAsStringSync('new');

      await publication.activateStagedSdk(staged, destination);

      expect(File(p.join(destination, 'new.txt')).readAsStringSync(), 'new');
      expect(File(p.join(destination, 'old.txt')).existsSync(), isFalse);
      expect(staged.existsSync(), isFalse);
      expect(Directory('$destination.previous').existsSync(), isFalse);
    });

    test('restores the old SDK when publication fails', () async {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      final old = Directory(destination)..createSync();
      File(p.join(old.path, 'old.txt')).writeAsStringSync('old');
      final staged = Directory(p.join(root.path, 'Darwin.staging'))
        ..createSync();
      File(p.join(staged.path, 'new.txt')).writeAsStringSync('new');

      await expectLater(
        publication.activateStagedSdk(
          staged,
          destination,
          renameStaged: (_, _) async =>
              throw const FileSystemException('failed'),
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(File(p.join(destination, 'old.txt')).readAsStringSync(), 'old');
      expect(File(p.join(destination, 'new.txt')).existsSync(), isFalse);
      expect(File(p.join(staged.path, 'new.txt')).readAsStringSync(), 'new');
      expect(Directory('$destination.previous').existsSync(), isFalse);
    });

    test('rejects an incomplete staged SDK without touching the old one', () {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      final old = Directory(destination)..createSync();
      File(p.join(old.path, 'old.txt')).writeAsStringSync('old');
      final staged = Directory(p.join(root.path, 'Darwin.staging'))
        ..createSync();
      for (final name in ['info.json', 'swift-sdk.json', 'toolset.json']) {
        File(p.join(staged.path, name)).writeAsStringSync('{}');
      }
      Directory(
        p.join(
          staged.path,
          'Developer',
          'Platforms',
          'iPhoneOS.platform',
          'Developer',
          'SDKs',
          'iPhoneOS18.0.sdk',
        ),
      ).createSync(recursive: true);

      expect(
        () => publication.requireValidStagedSdk(staged.path),
        throwsA(isA<XcrossError>()),
      );
      expect(File(p.join(destination, 'old.txt')).readAsStringSync(), 'old');
    });

    test('clears a stale backup before another installation', () async {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      createValidBundle(destination);
      final backup = Directory('$destination.previous')..createSync();
      File(p.join(backup.path, 'old.txt')).writeAsStringSync('old');

      await publication.prepareExistingSdk(destination);

      expect(sdkFixtureRepository.isValidBundle(destination), isTrue);
      expect(backup.existsSync(), isFalse);
    });

    test('rejects a truncated simulator at the final publication gate', () {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      final staged = p.join(root.path, 'Darwin.staging');
      createValidBundle(destination);
      createValidBundle(staged);
      File(p.join(destination, 'old.txt')).writeAsStringSync('old');
      Directory(
        p.join(
          staged,
          'Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk',
        ),
      ).createSync(recursive: true);
      File(p.join(staged, 'swift-sdk.json')).writeAsStringSync(
        jsonEncode({
          'targetTriples': {
            const SimulatorBuildPlatform().swiftSdkTriple: <String, String>{},
          },
        }),
      );

      expect(
        () => publication.requireValidStagedSdk(staged),
        throwsA(isA<XcrossError>()),
      );
      expect(sdkFixtureRepository.isValidBundle(destination), isTrue);
      expect(File(p.join(destination, 'old.txt')).readAsStringSync(), 'old');
      expect(Directory('$destination.previous').existsSync(), isFalse);
    });
  });

  CpioEntry entry(String name, {int mode = 0x81a4, String data = ''}) =>
      CpioEntry(
        name: name,
        mode: mode,
        data: Uint8List.fromList(utf8.encode(data)),
      );

  group('Xcode.app import', () {
    late Directory root;
    late String app;
    late String destination;

    File sourceFile(String relative, String contents) =>
        File(p.joinAll([app, 'Contents', ...relative.split('/')]))
          ..createSync(recursive: true)
          ..writeAsStringSync(contents);

    setUp(() {
      root = Directory.systemTemp.createTempSync('xcross-native-sdk-');
      app = p.join(root.path, 'Xcode.app');
      destination = p.join(root.path, 'sdk');
    });
    tearDown(() => root.deleteSync(recursive: true));

    test(
      'copies both SDKs and descriptors without changing the source',
      () async {
        final sources = [
          for (final relative in sdkIncludedRoots)
            sourceFile('$relative/kept.txt', relative),
          for (final relative in sdkIncludedFiles)
            sourceFile(relative, relative),
        ];
        sourceFile('Developer/usr/bin/excluded', 'excluded');

        final count = await installer.writeSdkEntries(
          installer.xcodeAppEntries(app),
          destination,
        );

        expect(count, sdkIncludedRoots.length * 2 + sdkIncludedFiles.length);
        for (final file in sources) {
          final relative = p.relative(file.path, from: p.join(app, 'Contents'));
          expect(
            File(p.join(destination, relative)).readAsStringSync(),
            file.readAsStringSync(),
          );
        }
        expect(
          File(
            p.join(destination, 'Developer', 'usr', 'bin', 'excluded'),
          ).existsSync(),
          isFalse,
        );
        expect(
          Directory(
            p.join(app, 'Contents'),
          ).listSync(recursive: true).whereType<File>().length,
          sources.length + 1,
        );
      },
    );

    test('rejects non-Xcode directories before touching the install', () async {
      Directory(app).createSync();
      final runner = CommandRunner<void>('xcross', 'test')
        ..addCommand(SdkCommand(installer));
      await expectLater(
        runner.run(['sdk', 'install', app]),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains('No Xcode Developer directory'),
          ),
        ),
      );
      expect(Directory(destination).existsSync(), isFalse);
      await expectLater(
        installer.xcodeAppEntries(app).toList(),
        throwsA(isA<XcrossError>()),
      );
    });

    Map<String, String> snapshot(String path) => {
      for (final entity in Directory(path).listSync(recursive: true))
        p.relative(entity.path, from: path): entity is File
            ? base64Encode(entity.readAsBytesSync())
            : 'directory',
    };

    for (final archive in [false, true]) {
      for (final partial in [
        'empty leaf',
        'missing frameworks',
        'missing resources',
      ]) {
        test(
          'failed ${archive ? 'XIP' : 'app'} import preserves SDK and source: $partial',
          () async {
            const swift =
                'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift';
            for (final target in const <IosBuildPlatformInterface>[
              IPhoneBuildPlatform(),
              SimulatorBuildPlatform(),
            ]) {
              sourceFile(
                'Developer/Platforms/${target.platformName}.platform/Developer/SDKs/${target.platformName}26.5.sdk/System/Library/Frameworks/Foundation.framework/Foundation.tbd',
                '${target.sdkName} stub',
              );
            }
            sourceFile('$swift/iphoneos/layouts-arm64.yaml', 'layout');
            sourceFile(
              '$swift/iphonesimulator/libswiftCompatibility50.a',
              'resource',
            );
            await installer.writeSdkEntries(
              installer.xcodeAppEntries(app),
              destination,
            );
            await installer.materializeSwiftCompatibilityResources(destination);
            await installer.writeSwiftSdkBundleMetadata(destination);
            expect(sdkFixtureRepository.isValidBundle(destination), isTrue);
            final previous = snapshot(destination);
            const simulator =
                'Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk';
            final removed = switch (partial) {
              'empty leaf' => '$simulator/System',
              'missing frameworks' => '$simulator/System/Library/Frameworks',
              _ => '$swift/iphonesimulator',
            };
            Directory(
              p.joinAll([app, 'Contents', ...removed.split('/')]),
            ).deleteSync(recursive: true);
            final sourceBefore = snapshot(app);
            File? xip;
            List<int>? archiveBefore;
            if (archive) {
              final cpio = BytesBuilder();
              await for (final entry in installer.xcodeAppEntries(app)) {
                cpio.add(
                  buildCpioEntry(
                    name: 'Xcode.app/Contents/${entry.name}',
                    data: entry.data,
                    mode: entry.mode,
                  ),
                );
              }
              cpio.add(buildCpioTrailer());
              final bytes = cpio.takeBytes();
              xip = File(p.join(root.path, 'Xcode.xip'));
              xip.writeAsBytesSync(
                buildXar({
                  'Content': buildPbzx([
                    PbzxChunk(
                      decompressedSize: bytes.length,
                      bytes: xzCompress(bytes),
                    ),
                  ]),
                }),
              );
              archiveBefore = xip.readAsBytesSync();
            }
            final staged = Directory(p.join(root.path, 'sdk.staging'));
            await expectLater(() async {
              try {
                await installer.writeSdkEntries(
                  xip == null
                      ? installer.xcodeAppEntries(app)
                      : XcodeXipExtractor(sdkFixtureHost).extract(xip.path),
                  staged.path,
                );
                await installer.materializeSwiftCompatibilityResources(
                  staged.path,
                );
                await installer.writeSwiftSdkBundleMetadata(staged.path);
                publication.requireValidStagedSdk(staged.path);
                await publication.activateStagedSdk(staged, destination);
              } finally {
                if (staged.existsSync()) staged.deleteSync(recursive: true);
              }
            }, throwsA(isA<XcrossError>()));
            expect(snapshot(destination), previous);
            expect(sdkFixtureRepository.isValidBundle(destination), isTrue);
            expect(Directory('$destination.previous').existsSync(), isFalse);
            expect(staged.existsSync(), isFalse);
            expect(snapshot(app), sourceBefore);
            if (xip != null) expect(xip.readAsBytesSync(), archiveBefore);
          },
        );
      }
    }

    test(
      'preserves simulator aliases and does not follow source links',
      () async {
        const sdks =
            'Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs';
        final file = sourceFile(
          '$sdks/iPhoneSimulator.sdk/usr/include/header.h',
          'header',
        );
        final base = p.joinAll([app, 'Contents', ...sdks.split('/')]);
        await Link(
          p.join(base, 'iPhoneSimulator18.2.sdk'),
        ).create('iPhoneSimulator.sdk');

        await installer.writeSdkEntries(
          installer.xcodeAppEntries(app),
          destination,
        );

        final installed = p.joinAll([destination, ...sdks.split('/')]);
        expect(
          Link(p.join(installed, 'iPhoneSimulator18.2.sdk')).targetSync(),
          'iPhoneSimulator.sdk',
        );
        expect(
          sdkFixtureRepository.iosSdk(
            DarwinSdk(destination),
            target: const SimulatorBuildPlatform(),
          ),
          p.join(installed, 'iPhoneSimulator18.2.sdk'),
        );
        expect(file.readAsStringSync(), 'header');
      },
      skip: Platform.isWindows,
    );

    test('rejects links outside the isolated bundle', () async {
      const sdks =
          'Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs';
      sourceFile('$sdks/iPhoneSimulator18.2.sdk/header.h', 'header');
      final outside = Directory(p.join(root.path, 'outside'))..createSync();
      File(p.join(outside.path, 'secret')).writeAsStringSync('untouched');
      final link = p.joinAll([
        app,
        'Contents',
        ...sdks.split('/'),
        'outside.sdk',
      ]);
      await Link(link).create(outside.path);
      final entries = await installer.xcodeAppEntries(app).toList();
      expect(entries.any((entry) => entry.name.endsWith('/secret')), isFalse);

      await expectLater(
        installer.writeSdkEntries(Stream.fromIterable(entries), destination),
        throwsA(isA<XcrossError>()),
      );
      expect(
        File(p.join(outside.path, 'secret')).readAsStringSync(),
        'untouched',
      );
    }, skip: Platform.isWindows);

    test(
      'rejects source ancestors that redirect SDK roots outside the app',
      () async {
        final outside = Directory(p.join(root.path, 'outside', 'SDKs'))
          ..createSync(recursive: true);
        File(p.join(outside.path, 'secret')).writeAsStringSync('untouched');
        final developer = Directory(
          p.join(
            app,
            'Contents',
            'Developer',
            'Platforms',
            'iPhoneSimulator.platform',
          ),
        )..createSync(recursive: true);
        await Link(
          p.join(developer.path, 'Developer'),
        ).create(p.dirname(outside.path));

        await expectLater(
          installer.xcodeAppEntries(app).toList(),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              contains('source escapes the app'),
            ),
          ),
        );
        expect(
          File(p.join(outside.path, 'secret')).readAsStringSync(),
          'untouched',
        );
      },
      skip: Platform.isWindows,
    );
  });

  group('Xcode.app source boundaries', () {
    for (final ancestor in ['Contents', 'Contents/Developer']) {
      test('rejects an external $ancestor symlink', () async {
        final root = Directory.systemTemp.createTempSync(
          'xcross-sdk-boundary-',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final app = p.join(root.path, 'Xcode.app');
        final outside = p.join(root.path, 'outside');
        final relative = ancestor == 'Contents'
            ? 'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS18.2.sdk'
            : 'Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS18.2.sdk';
        Directory(
          p.joinAll([outside, ...relative.split('/')]),
        ).createSync(recursive: true);
        final link = p.joinAll([app, ...ancestor.split('/')]);
        Directory(p.dirname(link)).createSync(recursive: true);
        await Link(link).create(outside);

        await expectLater(
          installer.xcodeAppEntries(app).toList(),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              contains('source escapes the app'),
            ),
          ),
        );
      }, skip: Platform.isWindows);
    }

    test('accepts a symlink to the selected app itself', () async {
      final root = Directory.systemTemp.createTempSync('xcross-sdk-app-alias-');
      addTearDown(() => root.deleteSync(recursive: true));
      final app = Directory(p.join(root.path, 'Xcode-real.app'))..createSync();
      const relative = 'Developer/Platforms/iPhoneOS.platform/Info.plist';
      File(p.joinAll([app.path, 'Contents', ...relative.split('/')]))
        ..createSync(recursive: true)
        ..writeAsStringSync('descriptor');
      final alias = Link(p.join(root.path, 'Xcode.app'));
      await alias.create(app.path);
      final entries = await installer.xcodeAppEntries(alias.path).toList();
      expect(entries.single.name, relative);
      expect(utf8.decode(entries.single.data), 'descriptor');
    }, skip: Platform.isWindows);
  });

  group('SdkInstall.sdkRelativePath', () {
    test('includes simulator SDK, libraries and exact platform descriptor', () {
      const paths = [
        'Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator18.2.sdk/usr/include/stdio.h',
        'Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/Test.framework/Test',
        'Developer/Platforms/iPhoneSimulator.platform/Developer/Library/PrivateFrameworks/Test.framework/Test',
        'Developer/Platforms/iPhoneSimulator.platform/Developer/usr/lib/libTest.tbd',
        'Developer/Platforms/iPhoneSimulator.platform/Info.plist',
      ];
      for (final path in paths) {
        expect(SdkInstall.sdkRelativePath(path), path);
        expect(SdkInstall.sdkRelativePath('Xcode.app/Contents/$path'), path);
        expect(
          SdkInstall.sdkRelativePath(
            'Xcode.app/Contents/$path'.replaceAll('/', r'\'),
          ),
          path,
        );
      }
      expect(
        SdkInstall.sdkRelativePath(
          'Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs-other/file',
        ),
        isNull,
      );
      expect(
        SdkInstall.sdkRelativePath(
          'Developer/Platforms/iPhoneSimulator.platform/Info.plist/child',
        ),
        isNull,
      );
    });

    test('includes the exact iOS cross-SDK subset', () {
      final names = [
        for (final root in sdkIncludedRoots) 'Xcode.app/Contents/$root/kept',
      ];

      expect(names.map(SdkInstall.sdkRelativePath), [
        for (final root in sdkIncludedRoots) '$root/kept',
      ]);
      expect(
        SdkInstall.sdkRelativePath(sdkIncludedRoots.first),
        sdkIncludedRoots.first,
      );
    });

    test('excludes neighboring Xcode content', () {
      const excluded = [
        'Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX14.sdk/usr/include/stdio.h',
        'Xcode.app/Contents/Developer/Platforms/AppleTVSimulator.platform/Developer/SDKs/AppleTVSimulator18.2.sdk/usr/include/stdio.h',
        'Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/Library/OtherFrameworks/No.framework/file',
        'Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift',
        'Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-driver/file',
        'Xcode.app/Contents/Info.plist',
        'README.md',
      ];

      expect(excluded.map(SdkInstall.sdkRelativePath), everyElement(isNull));
    });

    test('strips the Xcode.app prefix from SDK files', () {
      const name =
          'Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/'
          'Developer/SDKs/iPhoneOS17.5.sdk/usr/include/stdio.h';
      expect(
        SdkInstall.sdkRelativePath(name),
        'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/'
        'iPhoneOS17.5.sdk/usr/include/stdio.h',
      );
    });
  });

  test('writes directories and materializes SDK symlinks', () async {
    final temp = Directory.systemTemp.createTempSync('xcross-sdk-entries-');
    addTearDown(() => temp.deleteSync(recursive: true));
    const sdk =
        'Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/'
        'Developer/SDKs/iPhoneOS17.5.sdk';

    final count = await materializedInstaller.writeSdkEntries(
      Stream.fromIterable([
        entry('$sdk/usr/include', mode: 0x41ed),
        entry('$sdk/usr/include/real.h', data: 'header'),
        entry('$sdk/usr/include/alias.h', mode: 0xa1ff, data: 'real.h'),
      ]),
      temp.path,
    );

    final include = p.join(
      temp.path,
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
      'iPhoneOS17.5.sdk',
      'usr',
      'include',
    );
    expect(count, 3);
    expect(Directory(include).existsSync(), isTrue);
    expect(File(p.join(include, 'alias.h')).readAsStringSync(), 'header');
  });

  test(
    'restores included cpio hard-link payloads from excluded entries',
    () async {
      final temp = Directory.systemTemp.createTempSync('xcross-sdk-hard-link-');
      addTearDown(() => temp.deleteSync(recursive: true));
      const canonical = [1, 2, 3, 4];
      const relative =
          'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/'
          'iPhoneOS18.2.sdk/usr/include/hard-link.h';
      final archive = BytesBuilder()
        ..add(
          buildCpioEntry(
            name:
                'Xcode.app/Contents/Developer/Platforms/'
                'AppleTVSimulator.platform/Developer/SDKs/'
                'AppleTVSimulator18.2.sdk/usr/include/hard-link.h',
            data: canonical,
            dev: 1,
            ino: 42,
            nlink: 2,
          ),
        )
        ..add(
          buildCpioEntry(
            name: 'Xcode.app/Contents/$relative',
            data: ascii.encode('NULLcanary'),
            dev: 1,
            ino: 42,
            nlink: 2,
          ),
        )
        ..add(buildCpioTrailer());

      final count = await installer.writeSdkEntries(
        CpioReader.read(Stream.value(archive.takeBytes())),
        temp.path,
      );

      expect(count, 1);
      expect(
        File(p.joinAll([temp.path, ...relative.split('/')])).readAsBytesSync(),
        canonical,
      );
    },
  );

  test('materializes SDK directories beyond Windows MAX_PATH', () async {
    final temp = Directory.systemTemp.createTempSync('xcross-sdk-long-path-');
    addTearDown(() {
      final path = Platform.isWindows
          ? '\\\\?\\${p.absolute(temp.path)}'
          : temp.path;
      Directory(path).deleteSync(recursive: true);
    });
    const sdk =
        'Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/'
        'Developer/SDKs/iPhoneOS26.6.sdk';
    final first = List.filled(90, 'a').join();
    final second = List.filled(90, 'b').join();
    final target = '$sdk/System/Library/Frameworks/$first/$second';

    await materializedInstaller.writeSdkEntries(
      Stream.fromIterable([
        entry(target, mode: 0x41ed),
        entry('$target/value.txt', data: 'long path'),
        entry(
          '$sdk/copied',
          mode: 0xa1ff,
          data: 'System/Library/Frameworks/$first/$second',
        ),
      ]),
      temp.path,
    );

    final copied = p.join(
      temp.path,
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
      'iPhoneOS26.6.sdk',
      'copied',
      'value.txt',
    );
    expect(p.join(temp.path, target).length, greaterThan(260));
    final ioCopied = Platform.isWindows
        ? '\\\\?\\${p.absolute(copied)}'
        : copied;
    expect(File(ioCopied).readAsStringSync(), 'long path');
  });

  test('rejects archive traversal', () async {
    final temp = Directory.systemTemp.createTempSync('xcross-sdk-path-');
    addTearDown(() => temp.deleteSync(recursive: true));

    await expectLater(
      installer.writeSdkEntries(
        Stream.value(
          entry(
            'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/'
            'iPhoneOS17.5.sdk/../../../../../../info.json',
          ),
        ),
        temp.path,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('rejects SDK symlinks that escape the extraction root', () async {
    final temp = Directory.systemTemp.createTempSync('xcross-sdk-link-');
    addTearDown(() => temp.deleteSync(recursive: true));

    await expectLater(
      materializedInstaller.writeSdkEntries(
        Stream.value(
          entry(
            'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/'
            'iPhoneOS17.5.sdk/escape',
            mode: 0xa1ff,
            data: '../../../../../../../outside',
          ),
        ),
        temp.path,
      ),
      throwsA(isA<Exception>()),
    );
  });

  group('SDK symlink graph safety', () {
    const swift = 'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift';
    const clang = 'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang';
    late Directory fixture;
    late String destination;
    late File sentinel;

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('xcross-sdk-link-graph-');
      destination = p.join(fixture.path, 'scope', 'bundle');
      sentinel = File(p.join(fixture.path, 'victim', 'include', 'sentinel'))
        ..createSync(recursive: true)
        ..writeAsStringSync('untouched');
    });
    tearDown(() => fixture.deleteSync(recursive: true));

    Future<void> rejectsBeforePublication(
      List<CpioEntry> entries, {
      required SdkArchiveLinksInterface links,
    }) async {
      var published = 0;
      await expectLater(
        sdkFixtureInstaller(links: links).writeSdkEntries(
          Stream.fromIterable(entries),
          destination,
          onLinkProgress: (_, _) => published++,
        ),
        throwsA(isA<XcrossError>()),
      );
      expect(published, 0);
      expect(sentinel.readAsStringSync(), 'untouched');
      expect(sentinel.parent.listSync().length, 1);
      expect(
        Directory(
          destination,
        ).listSync(recursive: true, followLinks: false).whereType<Link>(),
        isEmpty,
      );
    }

    for (final policy in [
      ('preserved', PreservedSdkArchiveLinks(sdkFixtureHost)),
      ('materialized', MaterializedSdkArchiveLinks(sdkFixtureHost)),
    ]) {
      for (final reverse in [false, true]) {
        for (final reference in ['redirect', 'REDIRECT', 'hop']) {
          test(
            'rejects semantic dotdot escape ${policy.$1}/$reverse/$reference',
            () async {
              final links = [
                entry('$swift/redirect', mode: 0xa1ff, data: '../../../../../'),
                if (reference == 'hop')
                  entry('$swift/hop', mode: 0xa1ff, data: 'redirect'),
                entry(
                  '$swift/clang',
                  mode: 0xa1ff,
                  data: '$reference/../../../victim',
                ),
              ];
              await rejectsBeforePublication(
                reverse ? links.reversed.toList() : links,
                links: policy.$2,
              );
            },
            skip: policy.$1 == 'preserved' && Platform.isWindows,
          );
        }

        test('rejects link cycles ${policy.$1}/$reverse', () async {
          final links = [
            entry('$swift/first', mode: 0xa1ff, data: 'second'),
            entry('$swift/second', mode: 0xa1ff, data: 'FIRST'),
          ];
          await rejectsBeforePublication(
            reverse ? links.reversed.toList() : links,
            links: policy.$2,
          );
        }, skip: policy.$1 == 'preserved' && Platform.isWindows);

        for (final child in [
          entry('$swift/alias/child', mode: 0xa1ff, data: '../../outside'),
          entry('$swift/ALIAS/child', data: 'shadowed'),
          entry('$swift/alias', data: 'shadowed'),
          entry('$swift/ALIAS', mode: 0xa1ff, data: '../clang/18'),
        ]) {
          test(
            'rejects overlapping destinations ${policy.$1}/$reverse/${child.name}/${child.mode}',
            () async {
              final entries = [
                entry('$swift/alias', mode: 0xa1ff, data: '../clang/17'),
                child,
              ];
              await rejectsBeforePublication(
                reverse ? entries.reversed.toList() : entries,
                links: policy.$2,
              );
            },
            skip: policy.$1 == 'preserved' && Platform.isWindows,
          );
        }
      }

      test(
        'uses semantic targets for safe nested dotdot aliases ${policy.$1}',
        () async {
          await sdkFixtureInstaller(links: policy.$2).writeSdkEntries(
            Stream.fromIterable([
              entry('$clang/17', mode: 0x41ed),
              entry('$clang/18/include/header.h', data: 'correct target'),
              entry('$swift/18/include/header.h', data: 'lexical target'),
              entry(
                '$swift/alias',
                mode: 0xa1ff,
                data: 'redirect/../18/include',
              ),
              entry('$swift/redirect', mode: 0xa1ff, data: '../clang/17'),
            ]),
            destination,
          );
          expect(
            File(
              p.joinAll([
                destination,
                ...swift.split('/'),
                'alias',
                'header.h',
              ]),
            ).readAsStringSync(),
            'correct target',
          );
          expect(sentinel.readAsStringSync(), 'untouched');
        },
        skip: policy.$1 == 'preserved' && Platform.isWindows,
      );
    }

    test(
      'rejects recursive ancestor copies before materializing any link',
      () async {
        await rejectsBeforePublication([
          entry('$swift/header.h', data: 'header'),
          entry('$swift/copy.h', mode: 0xa1ff, data: 'header.h'),
          entry('$swift/ancestor', mode: 0xa1ff, data: '..'),
        ], links: MaterializedSdkArchiveLinks(sdkFixtureHost));
        expect(
          File(
            p.joinAll([destination, ...swift.split('/'), 'copy.h']),
          ).existsSync(),
          isFalse,
        );
      },
    );

    test('preserves internal POSIX ancestor and bundle aliases', () async {
      await installer.writeSdkEntries(
        Stream.fromIterable([
          entry('$swift/header.h', data: 'header'),
          entry('$swift/ancestor', mode: 0xa1ff, data: '..'),
          entry('$swift/bundle', mode: 0xa1ff, data: '../../../../../..'),
        ]),
        destination,
      );
      final installed = p.joinAll([destination, ...swift.split('/')]);
      expect(Link(p.join(installed, 'ancestor')).targetSync(), '..');
      expect(
        Directory(p.join(installed, 'bundle')).resolveSymbolicLinksSync(),
        Directory(destination).resolveSymbolicLinksSync(),
      );
      expect(sentinel.readAsStringSync(), 'untouched');
    }, skip: Platform.isWindows);
  });

  test('materializes the Swift compatibility layout', () async {
    final temp = Directory.systemTemp.createTempSync('xcross-sdk-layout-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final source = File(
      p.join(
        temp.path,
        'Developer',
        'Toolchains',
        'XcodeDefault.xctoolchain',
        'usr',
        'lib',
        'swift',
        'iphoneos',
        'layouts-arm64.yaml',
      ),
    );
    await source.parent.create(recursive: true);
    await source.writeAsBytes([1, 2, 3, 4]);

    await installer.materializeSwiftCompatibilityResources(temp.path);

    expect(
      File(
        p.join(
          temp.path,
          'Developer',
          'Runtimes',
          'XcodeDefault.xctoolchain',
          'usr',
          'bin',
          'layouts-arm64.yaml',
        ),
      ).readAsBytesSync(),
      [1, 2, 3, 4],
    );
  });

  test('uses clang beside the selected Swift executable', () async {
    final temp = Directory.systemTemp.createTempSync('xcross-sdk-clang-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final bin = await Directory(p.join(temp.path, 'bin')).create();
    final swift = File(
      p.join(bin.path, sdkFixtureRunner.hostExecutableName('swift')),
    )..createSync();
    final clang = File(
      p.join(bin.path, sdkFixtureRunner.hostExecutableName('clang')),
    )..createSync();
    final include = await Directory(
      p.join(temp.path, 'resource', 'include'),
    ).create(recursive: true);
    await File(p.join(include.path, 'arm_neon.h')).writeAsString('swift clang');

    await installer.replaceClangBuiltinHeaders(
      temp.path,
      locateTool: (name) async {
        expect(name, 'swift');
        return swift.path;
      },
      runProcess: (executable, arguments) async {
        // Stamping the bundle asks the selected Swift for its version.
        if (arguments.contains('--version')) {
          expect(
            File(executable).resolveSymbolicLinksSync(),
            swift.resolveSymbolicLinksSync(),
          );
          return const CapturedProcess(0, 'Swift version 6.3.2', '');
        }
        expect(
          File(executable).resolveSymbolicLinksSync(),
          clang.resolveSymbolicLinksSync(),
        );
        expect(arguments, ['-print-resource-dir']);
        return CapturedProcess(0, p.dirname(include.path), '');
      },
    );

    final destination = p.join(
      temp.path,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
      'clang',
      'include',
      'arm_neon.h',
    );
    expect(File(destination).readAsStringSync(), 'swift clang');
  });

  test('falls back to shipped headers when clang cannot run', () async {
    final temp = Directory.systemTemp.createTempSync('xcross-sdk-dll-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final usr = p.join(temp.path, 'usr');
    final bin = await Directory(p.join(usr, 'bin')).create(recursive: true);
    File(
      p.join(bin.path, sdkFixtureRunner.hostExecutableName('swift')),
    ).createSync();
    File(
      p.join(bin.path, sdkFixtureRunner.hostExecutableName('clang')),
    ).createSync();
    for (final version in ['9.0.1', '21', '19.1.7']) {
      final include = await Directory(
        p.join(usr, 'lib', 'clang', version, 'include'),
      ).create(recursive: true);
      await File(p.join(include.path, 'arm_neon.h')).writeAsString(version);
    }

    await installer.replaceClangBuiltinHeaders(
      temp.path,
      locateTool: (name) async =>
          p.join(bin.path, sdkFixtureRunner.hostExecutableName('swift')),
      // 0xC0000135 (STATUS_DLL_NOT_FOUND) with no output on either stream is
      // exactly what Windows reports when the Swift runtime is off PATH.
      runProcess: (executable, arguments) async =>
          const CapturedProcess(0xC0000135, '', ''),
    );

    final destination = p.join(
      temp.path,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
      'clang',
      'include',
      'arm_neon.h',
    );
    expect(File(destination).readAsStringSync(), '21');
  });

  test('reports the DLL hint when no shipped headers exist', () async {
    final temp = Directory.systemTemp.createTempSync('xcross-sdk-nodir-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final bin = await Directory(
      p.join(temp.path, 'usr', 'bin'),
    ).create(recursive: true);
    File(
      p.join(bin.path, sdkFixtureRunner.hostExecutableName('swift')),
    ).createSync();
    File(
      p.join(bin.path, sdkFixtureRunner.hostExecutableName('clang')),
    ).createSync();

    await expectLater(
      installer.replaceClangBuiltinHeaders(
        temp.path,
        locateTool: (name) async =>
            p.join(bin.path, sdkFixtureRunner.hostExecutableName('swift')),
        runProcess: (executable, arguments) async =>
            const CapturedProcess(0xC0000135, '', ''),
      ),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('exited 3221225781'),
            contains('STATUS_DLL_NOT_FOUND'),
          ),
        ),
      ),
    );
  });

  test('writes Swift SDK artifact metadata for the extracted tree', () async {
    final bundle = Directory.systemTemp.createTempSync('xcross-sdk-metadata-');
    addTearDown(() => bundle.deleteSync(recursive: true));
    final sdkRoot = p.join(
      bundle.path,
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
      'iPhoneOS18.2.sdk',
    );
    await Directory(
      p.join(sdkRoot, 'System', 'Library', 'Frameworks'),
    ).create(recursive: true);
    await Directory(
      p.join(sdkRoot, 'usr', 'include', 'c++', 'v1'),
    ).create(recursive: true);
    final layout = File(
      p.join(
        bundle.path,
        'Developer',
        'Toolchains',
        'XcodeDefault.xctoolchain',
        'usr',
        'lib',
        'swift',
        'iphoneos',
        'layouts-arm64.yaml',
      ),
    );
    await layout.parent.create(recursive: true);
    await layout.writeAsString('layout');
    await installer.materializeSwiftCompatibilityResources(bundle.path);

    await installer.writeSwiftSdkBundleMetadata(bundle.path);

    final info =
        jsonDecode(File(p.join(bundle.path, 'info.json')).readAsStringSync())
            as Map<String, dynamic>;
    final artifact =
        (info['artifacts'] as Map<String, dynamic>)['xcross-darwin']
            as Map<String, dynamic>;
    final variant =
        (artifact['variants'] as List).single as Map<String, dynamic>;
    expect(info['schemaVersion'], '1.0');
    expect(artifact['type'], 'swiftSDK');
    expect(variant['path'], '.');
    expect(variant['supportedTriples'], [
      'x86_64-unknown-linux-gnu',
      'aarch64-unknown-linux-gnu',
      'x86_64-unknown-windows-msvc',
      'aarch64-unknown-windows-msvc',
      'x86_64-apple-macosx',
      'arm64-apple-macosx',
    ]);

    final swiftSdk =
        jsonDecode(
              File(p.join(bundle.path, 'swift-sdk.json')).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final target =
        (swiftSdk['targetTriples'] as Map<String, dynamic>)['arm64-apple-ios']
            as Map<String, dynamic>;
    expect(swiftSdk['schemaVersion'], '4.0');
    expect((swiftSdk['targetTriples'] as Map).keys, ['arm64-apple-ios']);
    expect(
      target['sdkRootPath'],
      'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/'
      'iPhoneOS18.2.sdk',
    );
    expect(
      target['swiftResourcesPath'],
      'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift',
    );
    expect(
      target['swiftStaticResourcesPath'],
      'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static',
    );
    expect(target['includeSearchPaths'], [
      'Developer/Platforms/iPhoneOS.platform/Developer/usr/lib',
      'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS18.2.sdk/usr/include/c++/v1',
    ]);
    expect(target['librarySearchPaths'], [
      'Developer/Platforms/iPhoneOS.platform/Developer/usr/lib',
    ]);
    expect(target['toolsetPaths'], ['toolset.json']);

    final toolset =
        jsonDecode(File(p.join(bundle.path, 'toolset.json')).readAsStringSync())
            as Map<String, dynamic>;
    expect(toolset, {
      'schemaVersion': '1.0',
      'swiftCompiler': {
        'extraCLIOptions': [
          '-Xfrontend',
          '-enable-cross-import-overlays',
          '-use-ld=lld',
        ],
      },
    });
    expect(sdkFixtureRepository.isValidBundle(bundle.path), isTrue);
  });

  group('simulator SDK metadata', () {
    late Directory bundle;

    String sdkRoot(
      IosBuildPlatformInterface target, {
      String version = '18.2',
    }) => p.join(
      bundle.path,
      'Developer',
      'Platforms',
      '${target.platformName}.platform',
      'Developer',
      'SDKs',
      '${target.platformName}$version.sdk',
    );

    void createSimulatorSlice() {
      File(
          p.join(
            sdkRoot(const SimulatorBuildPlatform()),
            'System/Library/Frameworks/Foundation.framework/Foundation.tbd',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('stub');
      File(
          p.join(
            bundle.path,
            'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphonesimulator/libswiftCompatibility50.a',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('resource');
    }

    Map<String, dynamic> targetMetadata() =>
        (jsonDecode(
                  File(
                    p.join(bundle.path, 'swift-sdk.json'),
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>)['targetTriples']
            as Map<String, dynamic>;

    setUp(() {
      bundle = Directory.systemTemp.createTempSync(
        'xcross-simulator-metadata-',
      );
      Directory(
        sdkRoot(const IPhoneBuildPlatform()),
      ).createSync(recursive: true);
    });
    tearDown(() => bundle.deleteSync(recursive: true));

    test('adds ARM64 simulator metadata with platform-specific paths', () async {
      createSimulatorSlice();
      await installer.writeSwiftSdkBundleMetadata(bundle.path);
      final targets = targetMetadata();
      expect(targets.keys, ['arm64-apple-ios', 'arm64-apple-ios-simulator']);
      expect(targets['arm64-apple-ios-simulator'], {
        'sdkRootPath':
            'Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator18.2.sdk',
        'swiftResourcesPath':
            'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift',
        'swiftStaticResourcesPath':
            'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static',
        'includeSearchPaths': [
          'Developer/Platforms/iPhoneSimulator.platform/Developer/usr/lib',
          'Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator18.2.sdk/usr/include/c++/v1',
        ],
        'librarySearchPaths': [
          'Developer/Platforms/iPhoneSimulator.platform/Developer/usr/lib',
        ],
        'toolsetPaths': ['toolset.json'],
      });
      expect(
        (targets['arm64-apple-ios'] as Map)['sdkRootPath'],
        contains('iPhoneOS18.2.sdk'),
      );
    });

    test('uses shared toolchain C++ includes for both targets', () async {
      createSimulatorSlice();
      const include =
          'Developer/Toolchains/XcodeDefault.xctoolchain/usr/include/c++/v1';
      Directory(
        p.joinAll([bundle.path, ...include.split('/')]),
      ).createSync(recursive: true);
      await installer.writeSwiftSdkBundleMetadata(bundle.path);
      for (final target in targetMetadata().values) {
        expect((target as Map)['includeSearchPaths'], contains(include));
      }
    });

    test(
      'rejects an unversioned simulator SDK before writing metadata',
      () async {
        Directory(
          sdkRoot(const SimulatorBuildPlatform(), version: ''),
        ).createSync(recursive: true);
        await expectLater(
          installer.writeSwiftSdkBundleMetadata(bundle.path),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              contains('versioned iPhoneSimulator SDK'),
            ),
          ),
        );
        expect(
          File(p.join(bundle.path, 'swift-sdk.json')).existsSync(),
          isFalse,
        );
      },
    );

    test('rejects a present but empty simulator SDK directory', () async {
      Directory(
        p.dirname(sdkRoot(const SimulatorBuildPlatform())),
      ).createSync(recursive: true);
      await expectLater(
        installer.writeSwiftSdkBundleMetadata(bundle.path),
        throwsA(isA<DarwinSdkError>()),
      );
      expect(File(p.join(bundle.path, 'info.json')).existsSync(), isFalse);
    });

    test('rejects an empty versioned simulator leaf before metadata', () async {
      Directory(
        sdkRoot(const SimulatorBuildPlatform(), version: '26.5'),
      ).createSync(recursive: true);
      await expectLater(
        installer.writeSwiftSdkBundleMetadata(bundle.path),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains('incomplete iPhoneSimulator SDK'),
          ),
        ),
      );
      for (final name in ['swift-sdk.json', 'toolset.json', 'info.json']) {
        expect(File(p.join(bundle.path, name)).existsSync(), isFalse);
      }
    });

    test('still requires a device SDK for simulator-enabled bundles', () async {
      Directory(
        sdkRoot(const IPhoneBuildPlatform()),
      ).deleteSync(recursive: true);
      Directory(
        sdkRoot(const SimulatorBuildPlatform()),
      ).createSync(recursive: true);
      await expectLater(
        installer.writeSwiftSdkBundleMetadata(bundle.path),
        throwsA(isA<DarwinSdkError>()),
      );
    });

    for (final target in const <IosBuildPlatformInterface>[
      IPhoneBuildPlatform(),
      SimulatorBuildPlatform(),
    ]) {
      for (final relative in [
        'SDKSettings.json',
        'SDKSettings.plist',
        'System/Library/CoreServices/SystemVersion.plist',
      ]) {
        test(
          'invalidates SDK identity for ${target.sdkName} $relative changes',
          () async {
            final file =
                File(p.joinAll([sdkRoot(target), ...relative.split('/')]))
                  ..createSync(recursive: true)
                  ..writeAsStringSync('version one');
            final originalTime = file.lastModifiedSync();
            final before = await installer.sdkBuildIdentity(bundle.path);
            file.writeAsStringSync('version two');
            file.setLastModifiedSync(originalTime);
            final after = await installer.sdkBuildIdentity(bundle.path);
            final key = p
                .relative(file.path, from: bundle.path)
                .replaceAll(r'\', '/');
            final oldMetadata = (before['metadata']! as Map)[key]! as Map;
            final newMetadata = (after['metadata']! as Map)[key]! as Map;
            expect(oldMetadata['size'], newMetadata['size']);
            expect(oldMetadata['modified'], newMetadata['modified']);
            expect(oldMetadata['digest'], isNot(newMetadata['digest']));
            expect(before, isNot(after));
          },
        );
      }
    }

    test(
      'invalidates SDK identity when a simulator SDK is added or removed',
      () async {
        final deviceOnly = await installer.sdkBuildIdentity(bundle.path);
        final metadata =
            File(
                p.join(
                  sdkRoot(const SimulatorBuildPlatform()),
                  'SDKSettings.json',
                ),
              )
              ..createSync(recursive: true)
              ..writeAsStringSync('{}');
        final withSimulator = await installer.sdkBuildIdentity(bundle.path);
        expect(withSimulator, isNot(deviceOnly));
        metadata.parent.deleteSync(recursive: true);
        expect(await installer.sdkBuildIdentity(bundle.path), deviceOnly);
      },
    );
  });

  group('host toolchain stamp', () {
    /// A fake toolchain layout: `bin/swift` with a sibling `clang` that
    /// reports [resourceDir], and a `swift --version` answering [version].
    ({
      String swift,
      Future<String> Function(String) locate,
      Future<CapturedProcess> Function(String, List<String>) run,
    })
    fakeToolchain(Directory root, String version) {
      final bin = Directory(p.join(root.path, 'bin'))
        ..createSync(recursive: true);
      final swift = File(
        p.join(bin.path, sdkFixtureRunner.hostExecutableName('swift')),
      )..createSync();
      File(
        p.join(bin.path, sdkFixtureRunner.hostExecutableName('clang')),
      ).createSync();
      final include = Directory(p.join(root.path, 'resource', 'include'))
        ..createSync(recursive: true);
      File(p.join(include.path, 'arm_neon.h')).writeAsStringSync('headers');
      return (
        swift: swift.path,
        locate: (name) async => swift.path,
        run: (executable, arguments) async => arguments.contains('--version')
            ? CapturedProcess(0, version, '')
            : CapturedProcess(0, p.dirname(include.path), ''),
      );
    }

    test('records the toolchain the bundle was patched against', () async {
      final temp = Directory.systemTemp.createTempSync('xcross-stamp-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final bundle = Directory(p.join(temp.path, 'bundle'))..createSync();
      final tools = fakeToolchain(
        Directory(p.join(temp.path, 'tc')),
        'Swift version 6.3.2',
      );

      await installer.replaceClangBuiltinHeaders(
        bundle.path,
        locateTool: tools.locate,
        runProcess: tools.run,
      );

      final stamp = installer.readHostToolchainStamp(bundle.path);
      expect(stamp, isNotNull);
      expect(stamp!['version'], 'Swift version 6.3.2');
      expect(
        File(stamp['swift']!).resolveSymbolicLinksSync(),
        File(tools.swift).resolveSymbolicLinksSync(),
      );
    });

    test('no mismatch when the same toolchain is still selected', () async {
      final temp = Directory.systemTemp.createTempSync('xcross-stamp-same-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final bundle = Directory(p.join(temp.path, 'bundle'))..createSync();
      final tools = fakeToolchain(
        Directory(p.join(temp.path, 'tc')),
        'Swift version 6.3.2',
      );
      await installer.replaceClangBuiltinHeaders(
        bundle.path,
        locateTool: tools.locate,
        runProcess: tools.run,
      );

      expect(
        await installer.hostToolchainMismatch(
          bundle.path,
          locateTool: tools.locate,
          runProcess: tools.run,
        ),
        isNull,
      );
    });

    test('reports both versions after the host Swift changes', () async {
      final temp = Directory.systemTemp.createTempSync('xcross-stamp-drift-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final bundle = Directory(p.join(temp.path, 'bundle'))..createSync();
      final installed = fakeToolchain(
        Directory(p.join(temp.path, 'tc')),
        'Swift version 6.3.2',
      );
      await installer.replaceClangBuiltinHeaders(
        bundle.path,
        locateTool: installed.locate,
        runProcess: installed.run,
      );

      // Same install path, upgraded in place: exactly what swiftly and mise do.
      final upgraded = fakeToolchain(
        Directory(p.join(temp.path, 'tc')),
        'Swift version 6.3.3',
      );
      final mismatch = await installer.hostToolchainMismatch(
        bundle.path,
        locateTool: upgraded.locate,
        runProcess: upgraded.run,
      );

      expect(mismatch, isNotNull);
      expect(mismatch, contains('Swift version 6.3.2'));
      expect(mismatch, contains('Swift version 6.3.3'));
      expect(
        SdkInstall.mismatchGuidance(mismatch),
        contains('xcross sdk install'),
      );
    });

    test('an unstamped bundle is never reported as mismatched', () async {
      final temp = Directory.systemTemp.createTempSync('xcross-stamp-old-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final tools = fakeToolchain(
        Directory(p.join(temp.path, 'tc')),
        'Swift version 6.3.3',
      );

      expect(installer.readHostToolchainStamp(temp.path), isNull);
      expect(
        await installer.hostToolchainMismatch(
          temp.path,
          locateTool: tools.locate,
          runProcess: tools.run,
        ),
        isNull,
      );
    });

    test(
      'falls back to the toolchain path when versions are unavailable',
      () async {
        final temp = Directory.systemTemp.createTempSync('xcross-stamp-path-');
        addTearDown(() => temp.deleteSync(recursive: true));
        final bundle = Directory(p.join(temp.path, 'bundle'))..createSync();
        final installed = fakeToolchain(Directory(p.join(temp.path, 'a')), '');
        await installer.replaceClangBuiltinHeaders(
          bundle.path,
          locateTool: installed.locate,
          runProcess: installed.run,
        );

        final other = fakeToolchain(Directory(p.join(temp.path, 'b')), '');
        expect(
          await installer.hostToolchainMismatch(
            bundle.path,
            locateTool: other.locate,
            runProcess: other.run,
          ),
          contains('now resolves to'),
        );
      },
    );
  });
}
