import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/basic/sdk_command.dart';
import 'package:xcross/src/shared/errors/errors.dart';

import '../../../darwin_sdk_kit/test/test_fixtures.dart';
import 'sdk_test_support.dart';

void main() {
  final sdkContext = SdkTestContext();
  final installer = sdkContext.installer();
  final materializedInstaller = sdkContext.installer(
    links: MaterializedSdkArchiveLinks(sdkContext.host),
  );

  CpioEntry entry(String name, {int mode = 0x81a4, String data = ''}) =>
      CpioEntry(
        name: name,
        mode: mode,
        data: Uint8List.fromList(utf8.encode(data)),
      );

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
        sdkContext
            .installer(links: links)
            .writeSdkEntries(
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
      ('preserved', PreservedSdkArchiveLinks(sdkContext.host)),
      ('materialized', MaterializedSdkArchiveLinks(sdkContext.host)),
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
          await sdkContext
              .installer(links: policy.$2)
              .writeSdkEntries(
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
        ], links: MaterializedSdkArchiveLinks(sdkContext.host));
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
}
