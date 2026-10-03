import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late MacOSHost host;
  late DarwinToolchainResolver<MacOSHost> resolver;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_darwin_sdk-');
    host = MacOSHost(temporaryDirectory: tmp.path);
    resolver = DarwinToolchainResolver(
      ProcessRunner(host),
      MacOSDarwinToolchainLocations(host),
    );
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

  group('IosTarget', () {
    test('preserves ARM64 device values', () {
      const target = IPhoneBuildPlatform();
      expect(target.sdkName, 'iphoneos');
      expect(target.platformName, 'iPhoneOS');
      expect(target.swiftSdkTriple, 'arm64-apple-ios');
      expect(target.linkerPlatform, 'ios');
      expect(target.buildTriple('15.0'), 'arm64-apple-ios15.0');
    });

    test('selects ARM64 simulator values', () {
      const target = SimulatorBuildPlatform();
      expect(target.sdkName, 'iphonesimulator');
      expect(target.platformName, 'iPhoneSimulator');
      expect(target.swiftSdkTriple, 'arm64-apple-ios-simulator');
      expect(target.linkerPlatform, 'ios-simulator');
      expect(target.buildTriple('15.0'), 'arm64-apple-ios15.0-simulator');
      expect(target.buildTriple('26.1'), 'arm64-apple-ios26.1-simulator');
    });
  });

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
        expect(DarwinSdkRepository(host).isValidBundle(tmp.path), isTrue);
      },
    );

    test('accepts a populated simulator without an ARM64 simulator layout', () {
      createDeviceBundle(tmp.path);
      createSimulatorSlice(tmp.path);
      advertiseSimulator(tmp.path);
      expect(DarwinSdkRepository(host).isValidBundle(tmp.path), isTrue);
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
      expect(DarwinSdkRepository(host).isValidBundle(tmp.path), isFalse);
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
          expect(DarwinSdkRepository(host).isValidBundle(tmp.path), isFalse);
        });
      }
    }

    test('rejects an advertised simulator target with no slice', () {
      createDeviceBundle(tmp.path);
      advertiseSimulator(tmp.path);
      expect(DarwinSdkRepository(host).isValidBundle(tmp.path), isFalse);
    });

    for (final property in ['sdkRootPath', 'swiftResourcesPath']) {
      test(
        'rejects missing simulator metadata $property with a present slice',
        () {
          createDeviceBundle(tmp.path);
          createSimulatorSlice(tmp.path);
          advertiseSimulator(tmp.path, {property: 'missing'});
          expect(DarwinSdkRepository(host).isValidBundle(tmp.path), isFalse);
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
      expect(DarwinSdkRepository(host).isValidBundle(tmp.path), isFalse);
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
        ).installBundle,
        expected,
      );
      expect(DarwinSdk(expected).swiftSdkPath, expected);
    });

    test('repositories keep independent immutable install paths', () {
      final first = DarwinSdkRepository(
        host,
        installBundle: p.join(tmp.path, 'first'),
      );
      final second = DarwinSdkRepository(
        host,
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
        DarwinSdkRepository(host, installBundle: bundle).current(),
        isNull,
      );
      await File(p.join(bundle, 'info.json')).writeAsString('{}');
      expect(
        DarwinSdkRepository(host, installBundle: bundle).current(),
        isNull,
      );
      await File(p.join(bundle, 'swift-sdk.json')).writeAsString('{}');
      expect(
        DarwinSdkRepository(host, installBundle: bundle).current(),
        isNull,
      );
      await File(p.join(bundle, 'toolset.json')).writeAsString('{}');

      final sdk = DarwinSdkRepository(host, installBundle: bundle).current();
      expect(sdk, isNotNull);
      expect(sdk!.bundle, bundle);
      expect(runtimeLayout.readAsStringSync(), 'layout');

      await Directory(bundle).rename('$bundle.previous');
      expect(
        DarwinSdkRepository(host, installBundle: bundle).current()?.bundle,
        bundle,
      );
      expect(Directory('$bundle.previous').existsSync(), isFalse);
      expect(Directory(bundle).existsSync(), isTrue);

      await runtimeLayout.delete();
      expect(DarwinSdkRepository(host).isValidBundle(bundle), isFalse);
    });

    test('rejects metadata with an empty SDK directory', () async {
      final bundle = p.join(tmp.path, 'xcross-darwin.artifactbundle');
      await Directory(
        p.join(sdksDir(bundle), 'iPhoneOS18.2.sdk'),
      ).create(recursive: true);
      await File(p.join(bundle, 'info.json')).writeAsString('{}');
      await File(p.join(bundle, 'swift-sdk.json')).writeAsString('{}');

      expect(DarwinSdkRepository(host).isValidBundle(bundle), isFalse);
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
        ).iosSdk(sdk, target: const IPhoneBuildPlatform()),
        DarwinSdkRepository(
          host,
        ).iosSdk(sdk, target: const IPhoneBuildPlatform()),
      );
      expect(
        DarwinSdkRepository(
          host,
        ).iosSdk(sdk, target: const SimulatorBuildPlatform()),
        p.join(
          sdksDir(tmp.path, target: const SimulatorBuildPlatform()),
          'iPhoneSimulator18.2.sdk',
        ),
      );
      expect(
        DarwinSdkRepository(
          host,
        ).iosSdk(sdk, target: const SimulatorBuildPlatform()),
        DarwinSdkRepository(
          host,
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
        ).iosSdk(sdk, target: const IPhoneBuildPlatform()),
        device,
      );
      expect(
        () => DarwinSdkRepository(
          host,
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
        ).iosSdk(DarwinSdk(tmp.path), target: const SimulatorBuildPlatform()),
        p.join(dir, 'iPhoneSimulator18.2.sdk'),
      );
    }, skip: Platform.isWindows);
  });

  group('typed targets', () {
    test('keeps the original coherent host', () {
      final phone = IPhoneTarget(host);
      final simulator = SimulatorTarget(host);
      expect(phone.host, same(host));
      expect(simulator.host, same(host));
      expect(
        phone.buildPlatform.minimumVersionFlag('15.0'),
        '-miphoneos-version-min=15.0',
      );
      expect(
        simulator.buildPlatform.minimumVersionFlag('15.0'),
        '-mios-simulator-version-min=15.0',
      );
    });
  });

  group('probeDarwinDriver', () {
    test('accepts a driver that only misses its input file', () async {
      final failure = await resolver.probeDarwinDriver(
        p.join(tmp.path, 'good-clang'),
        sysroot: tmp.path,
        runProcess: (executable, arguments) async => const CapturedProcess(
          1,
          '',
          "clang: error: no such file or directory: 'probe.c'",
        ),
      );
      expect(failure, isNull);
    });

    test('rejects a driver that fast-fails on the sysroot', () async {
      final failure = await resolver.probeDarwinDriver(
        p.join(tmp.path, 'swift-clang'),
        sysroot: tmp.path,
        runProcess: (executable, arguments) async =>
            const CapturedProcess(-1073740791, '', ''),
      );
      expect(failure, allOf(contains('crashed'), contains('0xC0000409')));
    });

    test('keeps probe verdicts separate for different SDK roots', () async {
      var runs = 0;
      Future<CapturedProcess> run(
        String executable,
        List<String> arguments,
      ) async {
        runs++;
        return CapturedProcess(
          arguments.contains('bad-sdk') ? -1073740791 : 1,
          '',
          '',
        );
      }

      expect(
        await resolver.probeDarwinDriver(
          'same-clang',
          sysroot: 'bad-sdk',
          runProcess: run,
        ),
        contains('crashed'),
      );
      expect(
        await resolver.probeDarwinDriver(
          'same-clang',
          sysroot: 'good-sdk',
          runProcess: run,
        ),
        isNull,
      );
      expect(
        await resolver.probeDarwinDriver(
          'same-clang',
          sysroot: 'good-sdk',
          runProcess: run,
        ),
        isNull,
      );
      expect(runs, 2);
    });

    test('does not share version cache across resolver instances', () async {
      final other = DarwinToolchainResolver(
        ProcessRunner(host),
        MacOSDarwinToolchainLocations(host),
      );
      expect(
        await resolver.clangMajorVersion(
          'same-clang',
          runProcess: (_, _) async =>
              const CapturedProcess(0, 'clang version 18.0', ''),
        ),
        18,
      );
      expect(
        await other.clangMajorVersion(
          'same-clang',
          runProcess: (_, _) async =>
              const CapturedProcess(0, 'clang version 21.0', ''),
        ),
        21,
      );
    });

    test('drives the probe without running any subcommand', () async {
      late List<String> seen;
      await resolver.probeDarwinDriver(
        p.join(tmp.path, 'recorded-clang'),
        sysroot: p.join(tmp.path, 'iPhoneOS26.5.sdk'),
        runProcess: (executable, arguments) async {
          seen = arguments;
          return const CapturedProcess(1, '', 'no such file');
        },
      );
      expect(seen.first, '-###');
      expect(
        seen,
        containsAllInOrder(['-isysroot', p.join(tmp.path, 'iPhoneOS26.5.sdk')]),
      );
    });
  });

  group('clang version vs SDK libc++', () {
    test('derives the minimum clang from the SDK libc++ version', () {
      final include = Directory(p.join(tmp.path, 'usr', 'include', 'c++', 'v1'))
        ..createSync(recursive: true);
      File(
        p.join(include.path, '__config'),
      ).writeAsStringSync('#  define _LIBCPP_VERSION 210106\n');
      expect(resolver.minimumClangForSdk(tmp.path), 19);
    });

    test('has no minimum without libc++ headers', () {
      expect(resolver.minimumClangForSdk(tmp.path), isNull);
    });

    test('flags an LLVM clang older than the minimum', () async {
      final reason = await resolver.clangTooOldForSdk(
        p.join(tmp.path, 'clang-18'),
        minimum: 19,
        runProcess: (_, _) async => const CapturedProcess(
          0,
          'Ubuntu clang version 18.1.3 (1ubuntu1)\n',
          '',
        ),
      );
      expect(reason, allOf(contains('clang 18'), contains('clang 19')));
    });

    test('accepts a new enough clang and Apple clang', () async {
      expect(
        await resolver.clangTooOldForSdk(
          p.join(tmp.path, 'clang-21'),
          minimum: 19,
          runProcess: (_, _) async =>
              const CapturedProcess(0, 'clang version 21.0.0 (swift)\n', ''),
        ),
        isNull,
      );
      expect(
        await resolver.clangTooOldForSdk(
          p.join(tmp.path, 'apple-clang'),
          minimum: 19,
          runProcess: (_, _) async => const CapturedProcess(
            0,
            'Apple clang version 17.0.0 (clang-1700.0.13.3)\n',
            '',
          ),
        ),
        isNull,
      );
    });
  });

  group('llvmToolDirs', () {
    test('covers both Windows LLVM installer layouts', () {
      final dirs = WindowsDarwinToolchainLocations(
        WindowsHost(
          environment: {
            'ProgramFiles': r'C:\Program Files',
            'LOCALAPPDATA': r'C:\Users\Mind\AppData\Local',
          },
        ),
      ).llvmToolDirectories();
      expect(dirs, [
        r'C:\Program Files\LLVM\bin',
        r'C:\Users\Mind\AppData\Local\Programs\LLVM\bin',
      ]);
    });

    test('skips roots the environment does not define', () {
      expect(
        WindowsDarwinToolchainLocations(WindowsHost()).llvmToolDirectories(),
        isEmpty,
      );
    });

    test('keeps Linux versioned LLVM discovery separate from Homebrew', () {
      for (final version in ['18', '22', '19.1']) {
        Directory(p.join(tmp.path, 'llvm-$version')).createSync();
      }
      Directory(p.join(tmp.path, 'unrelated')).createSync();
      final linux = LinuxHost(fileSystem: _FixtureFileSystem(tmp.path));
      expect(LinuxDarwinToolchainLocations(linux).llvmToolDirectories(), [
        '/usr/lib/llvm-22/bin',
        '/usr/lib/llvm-19.1/bin',
        '/usr/lib/llvm-18/bin',
      ]);
    });

    test('covers Homebrew lld and llvm prefixes', () {
      expect(
        MacOSDarwinToolchainLocations(host).llvmToolDirectories(),
        containsAll([
          '/opt/homebrew/opt/lld/bin',
          '/opt/homebrew/opt/llvm/bin',
          '/usr/local/opt/lld/bin',
          '/usr/local/opt/llvm/bin',
        ]),
      );
    });
  });

  group('probeIosSupport', () {
    test('accepts a linker that only misses its input file', () async {
      final failure = await resolver.probeIosSupport(
        p.join(tmp.path, 'good-ld64.lld'),
        runProcess: (executable, arguments) async => const CapturedProcess(
          1,
          '',
          'ld64.lld: error: cannot open xcross-ld64-probe.o: No such file',
        ),
      );
      expect(failure, isNull);
    });

    test('rejects a linker that refuses the iOS platform', () async {
      final failure = await resolver.probeIosSupport(
        p.join(tmp.path, 'swift-ld64.lld'),
        runProcess: (executable, arguments) async => const CapturedProcess(
          1,
          '',
          'ld64.lld: error: This version of lld does not support linking for '
              'platform iOS',
        ),
      );
      expect(failure, contains('does not support linking for platform iOS'));
    });

    test('rejects a linker without ARM64 Mach-O support', () async {
      final failure = await resolver.probeIosSupport(
        p.join(tmp.path, 'unsupported-arch-ld64.lld'),
        runProcess: (executable, arguments) async => const CapturedProcess(
          1,
          '',
          'ld64.lld: error: missing or unsupported -arch arm64',
        ),
      );
      expect(failure, contains('missing or unsupported -arch arm64'));
    });

    test('rejects a linker that dies without saying anything', () async {
      final failure = await resolver.probeIosSupport(
        p.join(tmp.path, 'crashing-ld64.lld'),
        runProcess: (executable, arguments) async =>
            const CapturedProcess(-1073740791, '', ''),
      );
      expect(failure, allOf(contains('crashed'), contains('0xC0000409')));
    });

    test('probes each linker once', () async {
      var runs = 0;
      final linker = p.join(tmp.path, 'counted-ld64.lld');
      Future<CapturedProcess> run(String executable, List<String> arguments) {
        runs++;
        return Future.value(
          const CapturedProcess(1, '', 'ld64.lld: error: cannot open'),
        );
      }

      await resolver.probeIosSupport(linker, runProcess: run);
      await resolver.probeIosSupport(linker, runProcess: run);
      expect(runs, 1);
    });

    test('asks the linker for an iOS dylib', () async {
      late List<String> seen;
      await resolver.probeIosSupport(
        p.join(tmp.path, 'recorded-ld64.lld'),
        runProcess: (executable, arguments) async {
          seen = arguments;
          return const CapturedProcess(1, '', 'cannot open');
        },
      );
      expect(
        seen,
        containsAllInOrder(['-platform_version', 'ios', '13.0', '13.0']),
      );
      expect(seen, contains('-dylib'));
    });
  });

  group('selectorStubDefect', () {
    Future<CapturedProcess> Function(String, List<String>) version(
      String banner,
    ) => (executable, arguments) async {
      expect(arguments, ['--version']);
      return CapturedProcess(0, banner, '');
    };

    test('parses distribution-prefixed and plain banners', () async {
      expect(
        await resolver.ld64LldVersion(
          p.join(tmp.path, 'ubuntu-ld64.lld'),
          runProcess: version(
            'Ubuntu LLD 18.1.3 (compatible with Apple linkers)\n',
          ),
        ),
        (18, 1),
      );
      expect(
        await resolver.ld64LldVersion(
          p.join(tmp.path, 'brew-ld64.lld'),
          runProcess: version('Homebrew LLD 22.1.8\n'),
        ),
        (22, 1),
      );
      expect(
        await resolver.ld64LldVersion(
          p.join(tmp.path, 'swift-ld64.lld'),
          runProcess: version(
            'LLD 21.0.0 (https://github.com/swiftlang/llvm-project.git abc)\n',
          ),
        ),
        (21, 0),
      );
    });

    test('flags lld 18 and accepts lld 19', () async {
      expect(
        await resolver.selectorStubDefect(
          p.join(tmp.path, 'lld18'),
          runProcess: version(
            'Ubuntu LLD 18.1.3 (compatible with Apple linkers)',
          ),
        ),
        allOf(contains('18.1'), contains('selector stubs')),
      );
      expect(
        await resolver.selectorStubDefect(
          p.join(tmp.path, 'lld19'),
          runProcess: version(
            'Ubuntu LLD 19.1.1 (compatible with Apple linkers)',
          ),
        ),
        isNull,
      );
    });

    test('does not hold an unreadable version against a linker', () async {
      expect(
        await resolver.selectorStubDefect(
          p.join(tmp.path, 'silent'),
          runProcess: version(''),
        ),
        isNull,
      );
      expect(
        await resolver.selectorStubDefect(
          p.join(tmp.path, 'broken'),
          runProcess: (executable, arguments) => throw StateError('no'),
        ),
        isNull,
      );
    });

    test('asks each linker for its version once', () async {
      var runs = 0;
      final linker = p.join(tmp.path, 'counted');
      Future<CapturedProcess> run(String executable, List<String> arguments) {
        runs++;
        return Future.value(const CapturedProcess(0, 'LLD 20.1.0', ''));
      }

      await resolver.selectorStubDefect(linker, runProcess: run);
      await resolver.selectorStubDefect(linker, runProcess: run);
      expect(runs, 1);
    });
  });
}

final class _FixtureFileSystem implements HostFileSystemInterface {
  const _FixtureFileSystem(this.root);
  final String root;
  String _path(String path) => path == '/usr/lib' ? root : path;
  @override
  File file(String path) => File(_path(path));
  @override
  Directory directory(String path) => Directory(_path(path));
  @override
  Link link(String path) => Link(_path(path));
  @override
  void makeExecutable(String path) {}
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      link(destination).create(target);
}
