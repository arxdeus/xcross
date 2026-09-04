import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/src/darwin_sdk.dart';
import 'package:darwin_sdk_kit/src/errors.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_darwin_sdk-');
  });

  tearDown(() => tmp.delete(recursive: true));

  String sdksDir(String bundle) => p.join(
    bundle,
    'Developer',
    'Platforms',
    'iPhoneOS.platform',
    'Developer',
    'SDKs',
  );

  group('native bundle', () {
    test('uses xcross artifact-bundle storage', () {
      final expected = p.join(
        tmp.path,
        'xcross',
        'swift-sdks',
        'xcross-darwin.artifactbundle',
      );
      expect(DarwinSdk.nativeInstallDir(configDir: tmp.path), expected);
      expect(DarwinSdk(expected).swiftSdkPath, expected);
    });

    test('configured bundle overrides the native install location', () {
      final bundle = p.join(tmp.path, 'configured.artifactbundle');
      addTearDown(DarwinSdk.resetInstallBundleOverride);

      DarwinSdk.configureInstallBundleOverride(bundle);

      expect(DarwinSdk.nativeInstallDir(), bundle);
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

      expect(DarwinSdk.current(bundle: bundle), isNull);
      await File(p.join(bundle, 'info.json')).writeAsString('{}');
      expect(DarwinSdk.current(bundle: bundle), isNull);
      await File(p.join(bundle, 'swift-sdk.json')).writeAsString('{}');
      expect(DarwinSdk.current(bundle: bundle), isNull);
      await File(p.join(bundle, 'toolset.json')).writeAsString('{}');

      final sdk = DarwinSdk.current(bundle: bundle);
      expect(sdk, isNotNull);
      expect(sdk!.bundle, bundle);
      expect(runtimeLayout.readAsStringSync(), 'layout');

      await runtimeLayout.delete();
      expect(DarwinSdk.isValidBundle(bundle), isFalse);
    });

    test('rejects metadata with an empty SDK directory', () async {
      final bundle = p.join(tmp.path, 'xcross-darwin.artifactbundle');
      await Directory(
        p.join(sdksDir(bundle), 'iPhoneOS18.2.sdk'),
      ).create(recursive: true);
      await File(p.join(bundle, 'info.json')).writeAsString('{}');
      await File(p.join(bundle, 'swift-sdk.json')).writeAsString('{}');

      expect(DarwinSdk.isValidBundle(bundle), isFalse);
    });
  });

  group('iPhoneOSSdk', () {
    test('prefers a versioned SDK over an unversioned one', () async {
      final dir = sdksDir(tmp.path);
      await Directory(p.join(dir, 'iPhoneOS.sdk')).create(recursive: true);
      await Directory(p.join(dir, 'iPhoneOS17.5.sdk')).create(recursive: true);

      final sdk = DarwinSdk(tmp.path);
      expect(sdk.iPhoneOSSdk(), p.join(dir, 'iPhoneOS17.5.sdk'));
    });

    test(
      'returns the only versioned SDK when no unversioned one exists',
      () async {
        final dir = sdksDir(tmp.path);
        await Directory(p.join(dir, 'iPhoneOS26.sdk')).create(recursive: true);

        final sdk = DarwinSdk(tmp.path);
        expect(sdk.iPhoneOSSdk(), p.join(dir, 'iPhoneOS26.sdk'));
      },
    );

    test('falls back to the unversioned SDK when it is the only one', () async {
      final dir = sdksDir(tmp.path);
      await Directory(p.join(dir, 'iPhoneOS.sdk')).create(recursive: true);

      final sdk = DarwinSdk(tmp.path);
      expect(sdk.iPhoneOSSdk(), p.join(dir, 'iPhoneOS.sdk'));
    });

    test(
      'throws DarwinSdkError when the SDKs dir exists but has no matches',
      () async {
        await Directory(sdksDir(tmp.path)).create(recursive: true);

        final sdk = DarwinSdk(tmp.path);
        expect(
          sdk.iPhoneOSSdk,
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
        sdk.iPhoneOSSdk,
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

  group('probeDarwinDriver', () {
    test('accepts a driver that only misses its input file', () async {
      final failure = await DarwinSdk.probeDarwinDriver(
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
      final failure = await DarwinSdk.probeDarwinDriver(
        p.join(tmp.path, 'swift-clang'),
        sysroot: tmp.path,
        runProcess: (executable, arguments) async =>
            const CapturedProcess(-1073740791, '', ''),
      );
      expect(failure, allOf(contains('crashed'), contains('0xC0000409')));
    });

    test('drives the probe without running any subcommand', () async {
      late List<String> seen;
      await DarwinSdk.probeDarwinDriver(
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

  group('llvmToolDirs', () {
    test('covers both Windows LLVM installer layouts', () {
      final dirs = DarwinSdk.llvmToolDirs(
        windows: true,
        environment: {
          'ProgramFiles': r'C:\Program Files',
          'LOCALAPPDATA': r'C:\Users\Mind\AppData\Local',
        },
      );
      expect(dirs, [
        r'C:\Program Files\LLVM\bin',
        r'C:\Users\Mind\AppData\Local\Programs\LLVM\bin',
      ]);
    });

    test('skips roots the environment does not define', () {
      expect(
        DarwinSdk.llvmToolDirs(windows: true, environment: const {}),
        isEmpty,
      );
    });

    test('covers Homebrew lld and llvm prefixes', () {
      expect(
        DarwinSdk.llvmToolDirs(windows: false),
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
      final failure = await DarwinSdk.probeIosSupport(
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
      final failure = await DarwinSdk.probeIosSupport(
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
      final failure = await DarwinSdk.probeIosSupport(
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
      final failure = await DarwinSdk.probeIosSupport(
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

      await DarwinSdk.probeIosSupport(linker, runProcess: run);
      await DarwinSdk.probeIosSupport(linker, runProcess: run);
      expect(runs, 1);
    });

    test('asks the linker for an iOS dylib', () async {
      late List<String> seen;
      await DarwinSdk.probeIosSupport(
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
}
