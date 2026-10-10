import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:darwin_sdk_kit/shared/archive/xcode_xip_extractor.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_build_platform.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/basic/sdk_command.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/sdk_install_constants.dart';

import '../../../darwin_sdk_kit/test/test_fixtures.dart';
import 'sdk_test_support.dart';

void main() {
  final sdkContext = SdkTestContext();
  final installer = sdkContext.installer();
  final publication = SdkInstallCommand(installer);

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
      testOn: '!windows',

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

    test(
      testOn: '!windows',
      'rejects non-Xcode directories before touching the install',
      () async {
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
      },
    );

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
          testOn: '!windows',

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
            expect(sdkContext.repository.isValidBundle(destination), isTrue);
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
                      : XcodeXipExtractor(sdkContext.host).extract(xip.path),
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
            expect(sdkContext.repository.isValidBundle(destination), isTrue);
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
          sdkContext.repository.iosSdk(
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
}
