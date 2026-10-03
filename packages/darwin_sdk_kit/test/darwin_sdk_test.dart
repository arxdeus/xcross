import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sdk_log_test_support.dart';

void main() {
  late Directory tmp;
  late MacOSHost host;
  late Log log;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross-sdk-fixture-');
    host = MacOSHost(temporaryDirectory: tmp.path);
    log = sdkTestLog();
  });
  tearDown(() => tmp.delete(recursive: true));
  String sdksDir(
    String bundle, {
    IosBuildPlatformInterface target = const IPhoneBuildPlatform(),
  }) => p.join(
    bundle,
    'Developer',
    'Platforms',
    '${target.platformName}.platform',
    'Developer',
    'SDKs',
  );

  group('native bundle', () {
    const swift = 'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift';

    void writeFile(String bundle, String relative, String contents) {
      File(p.joinAll([bundle, ...relative.split('/')]))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    void createDeviceBundle(String bundle) {
      for (final name in ['info.json', 'swift-sdk.json', 'toolset.json']) {
        writeFile(bundle, name, '{}');
      }
      Directory(
        p.join(
          sdksDir(bundle),
          'iPhoneOS26.5.sdk',
          'System/Library/Frameworks',
        ),
      ).createSync(recursive: true);
      writeFile(bundle, '$swift/iphoneos/layouts-arm64.yaml', 'layout');
      writeFile(
        bundle,
        'Developer/Runtimes/XcodeDefault.xctoolchain/usr/bin/layouts-arm64.yaml',
        'layout',
      );
    }

    void createSimulatorSlice(String bundle) {
      final simulator = p.join(
        sdksDir(bundle, target: const SimulatorBuildPlatform()),
        'iPhoneSimulator26.5.sdk',
      );
      writeFile(
        simulator,
        'System/Library/Frameworks/Foundation.framework/Foundation.tbd',
        'stub',
      );
      writeFile(
        bundle,
        '$swift/iphonesimulator/libswiftCompatibility50.a',
        'resource',
      );
    }

    void advertiseSimulator(String bundle, [Map<String, String>? properties]) {
      writeFile(
        bundle,
        'swift-sdk.json',
        jsonEncode({
          'targetTriples': {
            const SimulatorBuildPlatform().swiftSdkTriple:
                properties ?? <String, String>{},
          },
        }),
      );
    }

    test(
      'keeps device-only legacy bundles valid with shared Swift resources',
      () {
        createDeviceBundle(tmp.path);
        writeFile(
          tmp.path,
          '$swift/iphonesimulator/libswiftCompatibility50.a',
          'resource',
        );
        expect(
          DarwinSdkRepository(host, log: log).isValidBundle(tmp.path),
          isTrue,
        );
      },
    );

    test('accepts a populated simulator without an ARM64 simulator layout', () {
      createDeviceBundle(tmp.path);
      createSimulatorSlice(tmp.path);
      advertiseSimulator(tmp.path);
      expect(
        DarwinSdkRepository(host, log: log).isValidBundle(tmp.path),
        isTrue,
      );
      expect(
        File(
          p.join(tmp.path, swift, 'iphonesimulator/layouts-arm64.yaml'),
        ).existsSync(),
        isFalse,
      );
    });

    test('rejects an empty versioned simulator SDK leaf', () {
      createDeviceBundle(tmp.path);
      Directory(
        p.join(
          sdksDir(tmp.path, target: const SimulatorBuildPlatform()),
          'iPhoneSimulator26.5.sdk',
        ),
      ).createSync(recursive: true);
      expect(
        DarwinSdkRepository(host, log: log).isValidBundle(tmp.path),
        isFalse,
      );
    });

    for (final missing in ['frameworks', 'resources']) {
      for (final empty in [false, true]) {
        test('rejects ${empty ? 'empty' : 'missing'} simulator $missing', () {
          createDeviceBundle(tmp.path);
          createSimulatorSlice(tmp.path);
          final directory = Directory(
            missing == 'frameworks'
                ? p.join(
                    sdksDir(tmp.path, target: const SimulatorBuildPlatform()),
                    'iPhoneSimulator26.5.sdk/System/Library/Frameworks',
                  )
                : p.join(tmp.path, swift, 'iphonesimulator'),
          );
          directory.deleteSync(recursive: true);
          if (empty) directory.createSync();
          expect(
            DarwinSdkRepository(host, log: log).isValidBundle(tmp.path),
            isFalse,
          );
        });
      }
    }

    test('rejects an advertised simulator target with no slice', () {
      createDeviceBundle(tmp.path);
      advertiseSimulator(tmp.path);
      expect(
        DarwinSdkRepository(host, log: log).isValidBundle(tmp.path),
        isFalse,
      );
    });

    for (final property in ['sdkRootPath', 'swiftResourcesPath']) {
      test(
        'rejects missing simulator metadata $property with a present slice',
        () {
          createDeviceBundle(tmp.path);
          createSimulatorSlice(tmp.path);
          advertiseSimulator(tmp.path, {property: 'missing'});
          expect(
            DarwinSdkRepository(host, log: log).isValidBundle(tmp.path),
            isFalse,
          );
        },
      );
    }

    test('rejects a partial simulator platform with no SDKs directory', () {
      createDeviceBundle(tmp.path);
      writeFile(
        tmp.path,
        'Developer/Platforms/iPhoneSimulator.platform/Info.plist',
        'descriptor',
      );
      expect(
        DarwinSdkRepository(host, log: log).isValidBundle(tmp.path),
        isFalse,
      );
    });

    test('uses xcross artifact-bundle storage', () {
      final expected = p.join(
        tmp.path,
        'xcross',
        'swift-sdks',
        'xcross-darwin.artifactbundle',
      );
      expect(
        DarwinSdkRepository(
          MacOSHost(environment: {'XDG_CONFIG_HOME': tmp.path}),
          log: log,
        ).installBundle,
        expected,
      );
      expect(DarwinSdk(expected).swiftSdkPath, expected);
    });

    test('repositories keep independent immutable install paths', () {
      final first = DarwinSdkRepository(
        host,
        log: log,
        installBundle: p.join(tmp.path, 'first'),
      );
      final second = DarwinSdkRepository(
        host,
        log: log,
        installBundle: p.join(tmp.path, 'second'),
      );
      expect(first.installBundle, p.join(tmp.path, 'first'));
      expect(second.installBundle, p.join(tmp.path, 'second'));
    });

    test('current accepts only a complete bundle', () async {
      final bundle = p.join(tmp.path, 'xcross-darwin.artifactbundle');
      final frameworks = p.join(
        sdksDir(bundle),
        'iPhoneOS18.2.sdk',
        'System',
        'Library',
        'Frameworks',
      );
      await Directory(frameworks).create(recursive: true);
      final canonicalLayout = File(
        p.join(
          bundle,
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
      final runtimeLayout = File(
        p.join(
          bundle,
          'Developer',
          'Runtimes',
          'XcodeDefault.xctoolchain',
          'usr',
          'bin',
          'layouts-arm64.yaml',
        ),
      );
      await canonicalLayout.parent.create(recursive: true);
      await canonicalLayout.writeAsString('layout');

      expect(
        DarwinSdkRepository(host, log: log, installBundle: bundle).current(),
        isNull,
      );
      await File(p.join(bundle, 'info.json')).writeAsString('{}');
      expect(
        DarwinSdkRepository(host, log: log, installBundle: bundle).current(),
        isNull,
      );
      await File(p.join(bundle, 'swift-sdk.json')).writeAsString('{}');
      expect(
        DarwinSdkRepository(host, log: log, installBundle: bundle).current(),
        isNull,
      );
      await File(p.join(bundle, 'toolset.json')).writeAsString('{}');

      final sdk = DarwinSdkRepository(
        host,
        log: log,
        installBundle: bundle,
      ).current();
      expect(sdk, isNotNull);
      expect(sdk!.bundle, bundle);
      expect(runtimeLayout.readAsStringSync(), 'layout');

      await Directory(bundle).rename('$bundle.previous');
      expect(
        DarwinSdkRepository(
          host,
          log: log,
          installBundle: bundle,
        ).current()?.bundle,
        bundle,
      );
      expect(Directory('$bundle.previous').existsSync(), isFalse);
      expect(Directory(bundle).existsSync(), isTrue);

      await runtimeLayout.delete();
      expect(
        DarwinSdkRepository(host, log: log).isValidBundle(bundle),
        isFalse,
      );
    });

    test('rejects metadata with an empty SDK directory', () async {
      final bundle = p.join(tmp.path, 'xcross-darwin.artifactbundle');
      await Directory(
        p.join(sdksDir(bundle), 'iPhoneOS18.2.sdk'),
      ).create(recursive: true);
      await File(p.join(bundle, 'info.json')).writeAsString('{}');
      await File(p.join(bundle, 'swift-sdk.json')).writeAsString('{}');

      expect(
        DarwinSdkRepository(host, log: log).isValidBundle(bundle),
        isFalse,
      );
    });
  });

  group('iPhoneOSSdk', () {
    test('prefers a versioned SDK over an unversioned one', () async {
      final dir = sdksDir(tmp.path);
      await Directory(p.join(dir, 'iPhoneOS.sdk')).create(recursive: true);
      await Directory(p.join(dir, 'iPhoneOS17.5.sdk')).create(recursive: true);

      final sdk = DarwinSdk(tmp.path);
      expect(
        DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(sdk, target: const IPhoneBuildPlatform()),
        p.join(dir, 'iPhoneOS17.5.sdk'),
      );
    });

    test(
      'returns the only versioned SDK when no unversioned one exists',
      () async {
        final dir = sdksDir(tmp.path);
        await Directory(p.join(dir, 'iPhoneOS26.sdk')).create(recursive: true);

        final sdk = DarwinSdk(tmp.path);
        expect(
          DarwinSdkRepository(
            host,
            log: log,
          ).iosSdk(sdk, target: const IPhoneBuildPlatform()),
          p.join(dir, 'iPhoneOS26.sdk'),
        );
      },
    );

    test('falls back to the unversioned SDK when it is the only one', () async {
      final dir = sdksDir(tmp.path);
      await Directory(p.join(dir, 'iPhoneOS.sdk')).create(recursive: true);

      final sdk = DarwinSdk(tmp.path);
      expect(
        DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(sdk, target: const IPhoneBuildPlatform()),
        p.join(dir, 'iPhoneOS.sdk'),
      );
    });

    test(
      'throws DarwinSdkError when the SDKs dir exists but has no matches',
      () async {
        await Directory(sdksDir(tmp.path)).create(recursive: true);

        final sdk = DarwinSdk(tmp.path);
        expect(
          () => DarwinSdkRepository(
            host,
            log: log,
          ).iosSdk(sdk, target: const IPhoneBuildPlatform()),
          throwsA(
            isA<DarwinSdkError>().having(
              (error) => error.message,
              'message',
              contains('Could not find an iPhoneOS SDK'),
            ),
          ),
        );
      },
    );

    test('throws DarwinSdkError when the SDKs dir does not exist', () {
      final sdk = DarwinSdk(tmp.path);
      expect(
        () => DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(sdk, target: const IPhoneBuildPlatform()),
        throwsA(
          isA<DarwinSdkError>().having(
            (error) => error.message,
            'message',
            contains('Could not find an iPhoneOS SDK'),
          ),
        ),
      );
    });
  });

  group('iosSdk', () {
    test('keeps device default and selects simulator independently', () async {
      for (final target in const <IosBuildPlatformInterface>[
        IPhoneBuildPlatform(),
        SimulatorBuildPlatform(),
      ]) {
        final dir = sdksDir(tmp.path, target: target);
        await Directory(
          p.join(dir, '${target.platformName}.sdk'),
        ).create(recursive: true);
        await Directory(
          p.join(dir, '${target.platformName}18.2.sdk'),
        ).create(recursive: true);
      }
      final sdk = DarwinSdk(tmp.path);
      expect(
        DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(sdk, target: const IPhoneBuildPlatform()),
        DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(sdk, target: const IPhoneBuildPlatform()),
      );
      expect(
        DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(sdk, target: const SimulatorBuildPlatform()),
        p.join(
          sdksDir(tmp.path, target: const SimulatorBuildPlatform()),
          'iPhoneSimulator18.2.sdk',
        ),
      );
      expect(
        DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(sdk, target: const SimulatorBuildPlatform()),
        DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(sdk, target: const SimulatorBuildPlatform()),
      );
    });

    test('allows a device-only bundle without a simulator fallback', () async {
      final device = p.join(sdksDir(tmp.path), 'iPhoneOS18.2.sdk');
      await Directory(device).create(recursive: true);
      final sdk = DarwinSdk(tmp.path);
      expect(
        DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(sdk, target: const IPhoneBuildPlatform()),
        device,
      );
      expect(
        () => DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(sdk, target: const SimulatorBuildPlatform()),
        throwsA(
          isA<DarwinSdkError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Could not find an iPhoneSimulator SDK'),
              contains('xcross sdk install'),
            ),
          ),
        ),
      );
    });

    test('falls back to an unversioned simulator SDK', () async {
      final simulator = p.join(
        sdksDir(tmp.path, target: const SimulatorBuildPlatform()),
        'iPhoneSimulator.sdk',
      );
      await Directory(simulator).create(recursive: true);
      expect(
        DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(DarwinSdk(tmp.path), target: const SimulatorBuildPlatform()),
        simulator,
      );
    });

    test('rejects a simulator SDK directory without matching SDKs', () async {
      final dir = sdksDir(tmp.path, target: const SimulatorBuildPlatform());
      await Directory(p.join(dir, 'iPhoneOS18.2.sdk')).create(recursive: true);
      await File(p.join(dir, 'iPhoneSimulator18.2.sdk')).writeAsString('file');
      expect(
        () => DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(DarwinSdk(tmp.path), target: const SimulatorBuildPlatform()),
        throwsA(isA<DarwinSdkError>()),
      );
    });

    test('resolves versioned simulator SDK aliases', () async {
      final dir = sdksDir(tmp.path, target: const SimulatorBuildPlatform());
      await Directory(
        p.join(dir, 'iPhoneSimulator.sdk'),
      ).create(recursive: true);
      await Link(
        p.join(dir, 'iPhoneSimulator18.2.sdk'),
      ).create('iPhoneSimulator.sdk');
      expect(
        DarwinSdkRepository(
          host,
          log: log,
        ).iosSdk(DarwinSdk(tmp.path), target: const SimulatorBuildPlatform()),
        p.join(dir, 'iPhoneSimulator18.2.sdk'),
      );
    }, skip: Platform.isWindows);
  });
}
