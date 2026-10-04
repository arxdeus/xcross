import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/errors.dart';

import 'sdk_test_support.dart';

void main() {
  final sdkContext = SdkTestContext();
  tearDownAll(sdkContext.close);
  final installer = sdkContext.installer();

  for (final root in [
    r'C:\fixture\Darwin.artifactbundle',
    r'\\server\share\Darwin.artifactbundle',
  ]) {
    test('writes host-relative Windows SDK metadata for $root', () async {
      final temp = Directory.systemTemp.createTempSync(
        'xcross-sdk-win-metadata-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final paths = WindowsHost(currentDirectory: r'C:\fixture').paths;
      final fileSystem = WindowsSdkMetadataFileSystemFixture(paths, root, temp);
      final host = WindowsHost(paths: paths, fileSystem: fileSystem);
      final io = SdkMetadataTestIo();
      addTearDown(io.close);
      final runner = ProcessRunner(
        host,
        log: sdkContext.log,
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );
      final repository = DarwinSdkRepository(host, log: sdkContext.log);
      final sdkRoot = paths.context.join(
        root,
        'Developer',
        'Platforms',
        'iPhoneOS.platform',
        'Developer',
        'SDKs',
        'iPhoneOS18.2.sdk',
      );
      final installation = SdkInstall(
        runner,
        repository,
        links: MaterializedSdkArchiveLinks(host),
        swiftInstallGuidance: 'fixture',
        swiftBuildTools: const ['swift-build'],
        metadataPlatforms: [WindowsSdkMetadataPlatformFixture(sdkRoot)],
      );
      await installation.writeSwiftSdkBundleMetadata(root);
      final metadata =
          jsonDecode(
                File(p.join(temp.path, 'swift-sdk.json')).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final target =
          (metadata['targetTriples']
                  as Map<String, dynamic>)[const IPhoneBuildPlatform()
                  .swiftSdkTriple]
              as Map<String, dynamic>;
      expect(
        target['sdkRootPath'],
        'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS18.2.sdk',
      );
      expect(target['includeSearchPaths'], [
        'Developer/Platforms/iPhoneOS.platform/Developer/usr/lib',
        'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS18.2.sdk/usr/include/c++/v1',
      ]);
    });
  }

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
    expect(sdkContext.repository.isValidBundle(bundle.path), isTrue);
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
}

final class WindowsSdkMetadataPlatformFixture
    implements SdkMetadataPlatformInterface<WindowsHost> {
  const WindowsSdkMetadataPlatformFixture(this.sdkRoot);
  final String sdkRoot;
  @override
  IosBuildPlatformInterface get buildPlatform => const IPhoneBuildPlatform();
  @override
  String resolveSdkRoot(
    DarwinSdkRepository<WindowsHost> repository,
    DarwinSdk sdk,
  ) => sdkRoot;
}

final class WindowsSdkMetadataFileSystemFixture
    implements HostFileSystemInterface {
  const WindowsSdkMetadataFileSystemFixture(
    this.paths,
    this.root,
    this.backing,
  );
  final HostPathsInterface paths;
  final String root;
  final Directory backing;
  String localPath(String path) => p.joinAll([
    backing.path,
    ...paths.context.relative(path, from: root).split(r'\'),
  ]);
  @override
  File file(String path) => File(localPath(path));
  @override
  Directory directory(String path) => Directory(localPath(path));
  @override
  Link link(String path) => Link(localPath(path));
  @override
  void makeExecutable(String path) => throw UnsupportedError(path);
  @override
  void setPermissions(String path, int mode) => throw UnsupportedError(path);
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      throw UnsupportedError(destination);
}

final class SdkMetadataTestIo {
  SdkMetadataTestIo() {
    outputController.stream.listen((_) {});
    errorController.stream.listen((_) {});
    output = IOSink(outputController.sink);
    error = IOSink(errorController.sink);
  }

  final Stream<List<int>> input = const Stream<List<int>>.empty();
  final StreamController<List<int>> outputController =
      StreamController<List<int>>();
  final StreamController<List<int>> errorController =
      StreamController<List<int>>();
  late final IOSink output;
  late final IOSink error;

  Future<void> close() async {
    await Future.wait([output.close(), error.close()]);
  }
}
