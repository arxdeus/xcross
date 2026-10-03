import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as hook;

void main() {
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
