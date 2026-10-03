import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as hook;

void main() {
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
                environment,
                required includeParentEnvironment,
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
                    environment,
                    required includeParentEnvironment,
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
