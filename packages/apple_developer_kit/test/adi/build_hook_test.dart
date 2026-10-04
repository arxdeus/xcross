import 'dart:io';
import 'dart:isolate';

import 'package:code_assets/code_assets.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../hook/build.dart' as hook;

final String _packageRoot = Directory.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:apple_developer_kit/'))!,
).parent.path;

void main() {
  test('Windows builds the target-specific bridge for x64 and ARM64', () {
    for (final architecture in [Architecture.x64, Architecture.arm64]) {
      expect(hook.windowsBridgeSources(architecture), [
        'src/host/windows/adi/windows_abi_bridge.c',
      ]);
    }
  });

  test('Windows rejects architectures without a native ABI bridge', () {
    for (final architecture in [Architecture.ia32, Architecture.arm]) {
      expect(
        () => hook.windowsBridgeSources(architecture),
        throwsUnsupportedError,
      );
    }
  });

  test('POSIX bridge compiles the mapping owned by the target host', () {
    final headers = {
      OS.macOS: 'src/host/macos/adi/adi_posix_host_mapping.h',
      OS.linux: 'src/host/linux/adi/adi_posix_host_mapping.h',
    };
    for (final entry in headers.entries) {
      expect(hook.posixHostMappingHeader(entry.key), entry.value);
      expect(
        File(p.join(_packageRoot, entry.value)).existsSync(),
        isTrue,
        reason: entry.value,
      );
    }
    final shared = File(
      p.join(_packageRoot, 'src/host/shared/adi/posix_bridge.c'),
    ).readAsStringSync();
    expect(shared, contains('#include "adi_posix_host_mapping.h"'));
    expect(shared, isNot(contains('__APPLE__')));
    expect(shared, isNot(contains('__linux__')));
  });

  test('POSIX bridge has no mapping for non-POSIX targets', () {
    for (final os in [OS.windows, OS.iOS, OS.android]) {
      expect(() => hook.posixHostMappingHeader(os), throwsUnsupportedError);
    }
  });

  for (final sdkRoot in [null, '/bogus-sdk', '/Xcode/iPhoneOS.sdk']) {
    test(
      'macOS resolves native compiler and SDK with SDKROOT=$sdkRoot',
      () async {
        final environment = {
          'PATH': '/Xcode/toolchain/usr/bin:/nix/bin',
          'DEVELOPER_DIR': '/Alternate Xcode/Contents/Developer',
          if (sdkRoot != null) 'SDKROOT': sdkRoot,
        };
        final commands = <List<String>>[];
        final compiler = await hook.resolveMacOSCompiler(
          environment: environment,
          runProcess:
              (
                executable,
                arguments, {
                required includeParentEnvironment,
                environment,
              }) async {
                expect(executable, '/usr/bin/xcrun');
                expect(includeParentEnvironment, isFalse);
                expect(environment, {
                  'PATH': '/Xcode/toolchain/usr/bin:/nix/bin',
                  'DEVELOPER_DIR': '/Alternate Xcode/Contents/Developer',
                });
                commands.add(arguments);
                return ProcessResult(
                  0,
                  0,
                  commands.length == 1
                      ? '/Alternate Xcode/toolchain/usr/bin/clang\n'
                      : '/Alternate Xcode/MacOSX.sdk\n',
                  '',
                );
              },
        );
        expect(commands, [
          ['--sdk', 'macosx', '--find', 'clang'],
          ['--sdk', 'macosx', '--show-sdk-path'],
        ]);
        expect(compiler.executable, '/Alternate Xcode/toolchain/usr/bin/clang');
        expect(compiler.flags, ['-isysroot', '/Alternate Xcode/MacOSX.sdk']);
        expect(environment['SDKROOT'], sdkRoot);
      },
    );
  }

  for (final failedCall in [1, 2]) {
    for (final exitCode in [0, 1]) {
      test(
        'macOS rejects unresolved native path $failedCall/$exitCode',
        () async {
          var calls = 0;
          await expectLater(
            hook.resolveMacOSCompiler(
              environment: {},
              runProcess:
                  (
                    executable,
                    arguments, {
                    required includeParentEnvironment,
                    environment,
                  }) async {
                    calls++;
                    return ProcessResult(
                      0,
                      calls == failedCall ? exitCode : 0,
                      calls == failedCall ? ' \n' : '/toolchain/clang\n',
                      'resolution failed',
                    );
                  },
            ),
            exitCode == 0 ? throwsStateError : throwsA(isA<ProcessException>()),
          );
          expect(calls, failedCall);
        },
      );
    }
  }

  test('macOS hook honors both slice targets instead of compiler default', () {
    for (final host in [Architecture.arm64, Architecture.x64]) {
      for (final target in [Architecture.arm64, Architecture.x64]) {
        expect(
          hook.systemCompilerFlags(
            targetOS: OS.macOS,
            targetArchitecture: target,
            hostOS: OS.macOS,
            hostArchitecture: host,
          ),
          ['-arch', if (target == Architecture.arm64) 'arm64' else 'x86_64'],
        );
      }
    }
  });

  test('Linux native targets use host compiler', () {
    for (final arch in [Architecture.arm64, Architecture.x64]) {
      expect(
        hook.systemCompilerFlags(
          targetOS: OS.linux,
          targetArchitecture: arch,
          hostOS: OS.linux,
          hostArchitecture: arch,
        ),
        isEmpty,
      );
    }
  });

  test(
    'rejects unsupported cross builds before emitting a mislabeled asset',
    () {
      for (final (targetOS, targetArch, hostOS, hostArch) in [
        (OS.linux, Architecture.arm64, OS.linux, Architecture.x64),
        (OS.linux, Architecture.x64, OS.macOS, Architecture.x64),
        (OS.macOS, Architecture.arm64, OS.linux, Architecture.arm64),
        (OS.macOS, Architecture.arm, OS.macOS, Architecture.arm64),
        (OS.iOS, Architecture.arm64, OS.macOS, Architecture.arm64),
      ]) {
        expect(
          () => hook.systemCompilerFlags(
            targetOS: targetOS,
            targetArchitecture: targetArch,
            hostOS: hostOS,
            hostArchitecture: hostArch,
          ),
          throwsUnsupportedError,
        );
      }
    },
  );
}
