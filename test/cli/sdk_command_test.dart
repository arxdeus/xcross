import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/sdk_command.dart';

import '../../packages/darwin_sdk_kit/test/test_fixtures.dart';

void main() {
  CpioEntry entry(String name, {int mode = 0x81a4, String data = ''}) =>
      CpioEntry(
        name: name,
        mode: mode,
        data: Uint8List.fromList(utf8.encode(data)),
      );

  group('SdkInstall.sdkRelativePath', () {
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
        'Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator18.2.sdk/usr/include/stdio.h',
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
                'iPhoneSimulator.platform/Developer/SDKs/'
                'iPhoneSimulator18.2.sdk/usr/include/hard-link.h',
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
        expect(executable, clang.path);
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
      'Developer/Toolchains/XcodeDefault.xctoolchain/usr/include/c++/v1',
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
}
