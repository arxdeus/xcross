import 'dart:io';

import 'package:cli_kit/shared/process/process_models.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/windows/sdk/windows_swift_toolchain_host.dart';
import 'package:xcross/src/shared/cli/basic/sdk_install.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/sdk_swift_toolchain.dart';

import 'sdk_test_support.dart';

void main() {
  final sdkContext = SdkTestContext();
  tearDownAll(sdkContext.close);
  final installer = sdkContext.installer();

  test(
    testOn: '!windows',
    'uses clang beside the selected Swift executable',
    () async {
      final temp = Directory.systemTemp.createTempSync('xcross-sdk-clang-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final bin = await Directory(p.join(temp.path, 'bin')).create();
      final swift = File(
        p.join(bin.path, sdkContext.runner.hostExecutableName('swift')),
      )..createSync();
      final clang = File(
        p.join(bin.path, sdkContext.runner.hostExecutableName('clang')),
      )..createSync();
      final include = await Directory(
        p.join(temp.path, 'resource', 'include'),
      ).create(recursive: true);
      await File(
        p.join(include.path, 'arm_neon.h'),
      ).writeAsString('swift clang');

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
    },
  );

  test(
    testOn: '!windows',
    'falls back to shipped headers when clang cannot run',
    () async {
      final temp = Directory.systemTemp.createTempSync('xcross-sdk-dll-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final usr = p.join(temp.path, 'usr');
      final bin = await Directory(p.join(usr, 'bin')).create(recursive: true);
      File(
        p.join(bin.path, sdkContext.runner.hostExecutableName('swift')),
      ).createSync();
      File(
        p.join(bin.path, sdkContext.runner.hostExecutableName('clang')),
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
            p.join(bin.path, sdkContext.runner.hostExecutableName('swift')),
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
    },
  );

  test(
    testOn: '!windows',

    'uses the selected failure guidance when no shipped headers exist',
    () async {
      final temp = Directory.systemTemp.createTempSync('xcross-sdk-nodir-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final bin = await Directory(
        p.join(temp.path, 'usr', 'bin'),
      ).create(recursive: true);
      File(
        p.join(bin.path, sdkContext.runner.hostExecutableName('swift')),
      ).createSync();
      File(
        p.join(bin.path, sdkContext.runner.hostExecutableName('clang')),
      ).createSync();

      await expectLater(
        SdkSwiftToolchain(
          sdkContext.runner,
          const WindowsSwiftToolchainHost(),
        ).replaceClangBuiltinHeaders(
          temp.path,
          locateTool: (name) async =>
              p.join(bin.path, sdkContext.runner.hostExecutableName('swift')),
          runProcess: (executable, arguments) async =>
              const CapturedProcess(0xC0000135, '', ''),
        ),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            allOf(contains('exited 3221225781'), contains('runtime DLLs')),
          ),
        ),
      );

      await expectLater(
        installer.replaceClangBuiltinHeaders(
          temp.path,
          locateTool: (name) async =>
              p.join(bin.path, sdkContext.runner.hostExecutableName('swift')),
          runProcess: (executable, arguments) async =>
              const CapturedProcess(0xC0000135, '', ''),
        ),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('exited 3221225781'),
              isNot(contains('DLL')),
              isNot(contains('LOCALAPPDATA')),
            ),
          ),
        ),
      );
    },
  );

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
        p.join(bin.path, sdkContext.runner.hostExecutableName('swift')),
      )..createSync();
      File(
        p.join(bin.path, sdkContext.runner.hostExecutableName('clang')),
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

    test(
      testOn: '!windows',
      'records the toolchain the bundle was patched against',
      () async {
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
      },
    );

    test(
      testOn: '!windows',
      'no mismatch when the same toolchain is still selected',
      () async {
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
      },
    );

    test(
      testOn: '!windows',
      'reports both versions after the host Swift changes',
      () async {
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
      },
    );

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
      testOn: '!windows',

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
