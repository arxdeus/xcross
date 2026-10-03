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

void main() {
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
        Directory(SdkInstall.ioPath(deepPath)).createSync(recursive: true);
        File(
          SdkInstall.ioPath(p.join(deepPath, 'header.h')),
        ).writeAsStringSync('header');
      }
      final staged = Directory(p.join(root.path, 'Darwin.staging'))
        ..createSync();
      File(p.join(staged.path, 'new.txt')).writeAsStringSync('new');

      await SdkInstallCommand.activateStagedSdk(staged, destination);

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
        SdkInstallCommand.activateStagedSdk(
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
        () => SdkInstallCommand.requireValidStagedSdk(staged.path),
        throwsA(isA<XcrossError>()),
      );
      expect(File(p.join(destination, 'old.txt')).readAsStringSync(), 'old');
    });

    test('clears a stale backup before another installation', () async {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      createValidBundle(destination);
      final backup = Directory('$destination.previous')..createSync();
      File(p.join(backup.path, 'old.txt')).writeAsStringSync('old');

      await SdkInstallCommand.prepareExistingSdk(destination);

      expect(DarwinSdk.isValidBundle(destination), isTrue);
      expect(backup.existsSync(), isFalse);
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

        final count = await SdkInstall.writeSdkEntries(
          SdkInstall.xcodeAppEntries(app),
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
        ..addCommand(SdkCommand());
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
        SdkInstall.xcodeAppEntries(app).toList(),
        throwsA(isA<XcrossError>()),
      );
    });

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

        await SdkInstall.writeSdkEntries(
          SdkInstall.xcodeAppEntries(app),
          destination,
        );

        final installed = p.joinAll([destination, ...sdks.split('/')]);
        expect(
          Link(p.join(installed, 'iPhoneSimulator18.2.sdk')).targetSync(),
          'iPhoneSimulator.sdk',
        );
        expect(
          DarwinSdk(destination).iPhoneSimulatorSdk(),
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
      final entries = await SdkInstall.xcodeAppEntries(app).toList();
      expect(entries.any((entry) => entry.name.endsWith('/secret')), isFalse);

      await expectLater(
        SdkInstall.writeSdkEntries(Stream.fromIterable(entries), destination),
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
          SdkInstall.xcodeAppEntries(app).toList(),
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
          SdkInstall.xcodeAppEntries(app).toList(),
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
      final entries = await SdkInstall.xcodeAppEntries(alias.path).toList();
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

    final count = await SdkInstall.writeSdkEntries(
      Stream.fromIterable([
        entry('$sdk/usr/include', mode: 0x41ed),
        entry('$sdk/usr/include/real.h', data: 'header'),
        entry('$sdk/usr/include/alias.h', mode: 0xa1ff, data: 'real.h'),
      ]),
      temp.path,
      materializeLinks: true,
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

      final count = await SdkInstall.writeSdkEntries(
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

    await SdkInstall.writeSdkEntries(
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
      materializeLinks: true,
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
      SdkInstall.writeSdkEntries(
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
      SdkInstall.writeSdkEntries(
        Stream.value(
          entry(
            'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/'
            'iPhoneOS17.5.sdk/escape',
            mode: 0xa1ff,
            data: '../../../../../../../outside',
          ),
        ),
        temp.path,
        materializeLinks: true,
      ),
      throwsA(isA<Exception>()),
    );
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

    await SdkInstall.materializeSwiftCompatibilityResources(temp.path);

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
      p.join(bin.path, ProcessRunner.hostExecutableName('swift')),
    )..createSync();
    final clang = File(
      p.join(bin.path, ProcessRunner.hostExecutableName('clang')),
    )..createSync();
    final include = await Directory(
      p.join(temp.path, 'resource', 'include'),
    ).create(recursive: true);
    await File(p.join(include.path, 'arm_neon.h')).writeAsString('swift clang');

    await SdkInstall.replaceClangBuiltinHeaders(
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
      p.join(bin.path, ProcessRunner.hostExecutableName('swift')),
    ).createSync();
    File(
      p.join(bin.path, ProcessRunner.hostExecutableName('clang')),
    ).createSync();
    for (final version in ['9.0.1', '21', '19.1.7']) {
      final include = await Directory(
        p.join(usr, 'lib', 'clang', version, 'include'),
      ).create(recursive: true);
      await File(p.join(include.path, 'arm_neon.h')).writeAsString(version);
    }

    await SdkInstall.replaceClangBuiltinHeaders(
      temp.path,
      locateTool: (name) async =>
          p.join(bin.path, ProcessRunner.hostExecutableName('swift')),
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
      p.join(bin.path, ProcessRunner.hostExecutableName('swift')),
    ).createSync();
    File(
      p.join(bin.path, ProcessRunner.hostExecutableName('clang')),
    ).createSync();

    await expectLater(
      SdkInstall.replaceClangBuiltinHeaders(
        temp.path,
        locateTool: (name) async =>
            p.join(bin.path, ProcessRunner.hostExecutableName('swift')),
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
    await SdkInstall.materializeSwiftCompatibilityResources(bundle.path);

    await SdkInstall.writeSwiftSdkBundleMetadata(bundle.path);

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
    expect(DarwinSdk.isValidBundle(bundle.path), isTrue);
  });

  group('simulator SDK metadata', () {
    late Directory bundle;

    String sdkRoot(IosTarget target, {String version = '18.2'}) => p.join(
      bundle.path,
      'Developer',
      'Platforms',
      '${target.platformName}.platform',
      'Developer',
      'SDKs',
      '${target.platformName}$version.sdk',
    );

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
      Directory(sdkRoot(IosTarget.device)).createSync(recursive: true);
    });
    tearDown(() => bundle.deleteSync(recursive: true));

    test('adds ARM64 simulator metadata with platform-specific paths', () async {
      Directory(sdkRoot(IosTarget.simulator)).createSync(recursive: true);
      await SdkInstall.writeSwiftSdkBundleMetadata(bundle.path);
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
      Directory(sdkRoot(IosTarget.simulator)).createSync(recursive: true);
      const include =
          'Developer/Toolchains/XcodeDefault.xctoolchain/usr/include/c++/v1';
      Directory(
        p.joinAll([bundle.path, ...include.split('/')]),
      ).createSync(recursive: true);
      await SdkInstall.writeSwiftSdkBundleMetadata(bundle.path);
      for (final target in targetMetadata().values) {
        expect((target as Map)['includeSearchPaths'], contains(include));
      }
    });

    test(
      'rejects an unversioned simulator SDK before writing metadata',
      () async {
        Directory(
          sdkRoot(IosTarget.simulator, version: ''),
        ).createSync(recursive: true);
        await expectLater(
          SdkInstall.writeSwiftSdkBundleMetadata(bundle.path),
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
        p.dirname(sdkRoot(IosTarget.simulator)),
      ).createSync(recursive: true);
      await expectLater(
        SdkInstall.writeSwiftSdkBundleMetadata(bundle.path),
        throwsA(isA<DarwinSdkError>()),
      );
      expect(File(p.join(bundle.path, 'info.json')).existsSync(), isFalse);
    });

    test('still requires a device SDK for simulator-enabled bundles', () async {
      Directory(sdkRoot(IosTarget.device)).deleteSync(recursive: true);
      Directory(sdkRoot(IosTarget.simulator)).createSync(recursive: true);
      await expectLater(
        SdkInstall.writeSwiftSdkBundleMetadata(bundle.path),
        throwsA(isA<DarwinSdkError>()),
      );
    });

    for (final target in IosTarget.values) {
      for (final relative in [
        'SDKSettings.json',
        'SDKSettings.plist',
        'System/Library/CoreServices/SystemVersion.plist',
      ]) {
        test(
          'invalidates SDK identity for ${target.name} $relative changes',
          () async {
            final file =
                File(p.joinAll([sdkRoot(target), ...relative.split('/')]))
                  ..createSync(recursive: true)
                  ..writeAsStringSync('version one');
            final originalTime = file.lastModifiedSync();
            final before = await SdkInstall.sdkBuildIdentity(bundle.path);
            file.writeAsStringSync('version two');
            file.setLastModifiedSync(originalTime);
            final after = await SdkInstall.sdkBuildIdentity(bundle.path);
            final key = p
                .relative(file.path, from: bundle.path)
                .replaceAll(r'\', '/');
            final oldMetadata = (before['metadata'] as Map)[key] as Map;
            final newMetadata = (after['metadata'] as Map)[key] as Map;
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
        final deviceOnly = await SdkInstall.sdkBuildIdentity(bundle.path);
        final metadata =
            File(p.join(sdkRoot(IosTarget.simulator), 'SDKSettings.json'))
              ..createSync(recursive: true)
              ..writeAsStringSync('{}');
        final withSimulator = await SdkInstall.sdkBuildIdentity(bundle.path);
        expect(withSimulator, isNot(deviceOnly));
        metadata.parent.deleteSync(recursive: true);
        expect(await SdkInstall.sdkBuildIdentity(bundle.path), deviceOnly);
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
        p.join(bin.path, ProcessRunner.hostExecutableName('swift')),
      )..createSync();
      File(
        p.join(bin.path, ProcessRunner.hostExecutableName('clang')),
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

      await SdkInstall.replaceClangBuiltinHeaders(
        bundle.path,
        locateTool: tools.locate,
        runProcess: tools.run,
      );

      final stamp = SdkInstall.readHostToolchainStamp(bundle.path);
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
      await SdkInstall.replaceClangBuiltinHeaders(
        bundle.path,
        locateTool: tools.locate,
        runProcess: tools.run,
      );

      expect(
        await SdkInstall.hostToolchainMismatch(
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
      await SdkInstall.replaceClangBuiltinHeaders(
        bundle.path,
        locateTool: installed.locate,
        runProcess: installed.run,
      );

      // Same install path, upgraded in place: exactly what swiftly and mise do.
      final upgraded = fakeToolchain(
        Directory(p.join(temp.path, 'tc')),
        'Swift version 6.3.3',
      );
      final mismatch = await SdkInstall.hostToolchainMismatch(
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

      expect(SdkInstall.readHostToolchainStamp(temp.path), isNull);
      expect(
        await SdkInstall.hostToolchainMismatch(
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
        await SdkInstall.replaceClangBuiltinHeaders(
          bundle.path,
          locateTool: installed.locate,
          runProcess: installed.run,
        );

        final other = fakeToolchain(Directory(p.join(temp.path, 'b')), '');
        expect(
          await SdkInstall.hostToolchainMismatch(
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
