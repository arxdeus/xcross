import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/errors.dart';

void main() {
  group('ComposeHost artifacts', () {
    test('linux and windows use exact Kotlin Native Maven artifacts', () {
      expect(
        ComposeHost.linuxX64.hostArtifact('2.2.20'),
        'kotlin-native-prebuilt-2.2.20-linux-x86_64.tar.gz',
      );
      expect(
        ComposeHost.windowsX64.hostArtifact('2.2.20'),
        'kotlin-native-prebuilt-2.2.20-windows-x86_64.zip',
      );
      expect(
        ComposeHost.macosX64OverlayArtifact('2.2.20'),
        'kotlin-native-prebuilt-2.2.20-macos-x86_64.tar.gz',
      );
      expect(
        ComposeHost.macosArm64.hostArtifact('2.2.20'),
        'kotlin-native-prebuilt-2.2.20-macos-aarch64.tar.gz',
      );
      expect(
        ComposeHost.macosX64.hostArtifact('2.2.20'),
        ComposeHost.macosX64OverlayArtifact('2.2.20'),
      );
    });

    for (final architecture in ['arm64', 'aarch64', ' ARM64 ']) {
      test('resolves macOS $architecture with native POSIX tools', () {
        final host = ComposeHost.current(
          operatingSystem: 'macos',
          architecture: architecture,
        );
        expect(host, ComposeHost.macosArm64);
        expect(host.konanTarget, 'macos_arm64');
        expect(host.isMacOS, isTrue);
        expect(host.isWindows, isFalse);
        expect(host.javaExecutable('/jdk'), p.join('/jdk', 'bin', 'java'));
        expect(host.konancExecutable('/kn'), p.join('/kn', 'bin', 'konanc'));
        expect(host.invokeExecutable('/gradlew', ['build']), [
          '/gradlew',
          'build',
        ]);
      });
      test('rejects Windows $architecture', () {
        expect(
          () => ComposeHost.current(
            operatingSystem: 'windows',
            architecture: architecture,
          ),
          throwsA(isA<XcrossError>()),
        );
      });
    }

    for (final architecture in ['x64', 'x86_64', 'AMD64']) {
      for (final entry in {
        'linux': ComposeHost.linuxX64,
        'macos': ComposeHost.macosX64,
        'windows': ComposeHost.windowsX64,
      }.entries) {
        test('resolves ${entry.key} $architecture', () {
          expect(
            ComposeHost.current(
              operatingSystem: entry.key,
              architecture: architecture,
            ),
            entry.value,
          );
        });
      }
    }

    test('uses the runtime ABI rather than environment architecture hints', () {
      final architecture = Abi.current().toString().split('_').last;
      if (architecture == 'x64' ||
          (Platform.isMacOS && architecture == 'arm64')) {
        expect(
          ComposeHost.current(),
          ComposeHost.current(
            operatingSystem: Platform.operatingSystem,
            architecture: architecture,
          ),
        );
      } else {
        expect(ComposeHost.current, throwsA(isA<XcrossError>()));
      }
    });

    test('does not treat unknown architectures as x64', () {
      for (final architecture in ['arm', 'ia32', 'riscv64', 'unknown']) {
        expect(
          () => ComposeHost.current(
            operatingSystem: 'linux',
            architecture: architecture,
          ),
          throwsA(isA<XcrossError>()),
        );
      }
    });

    test('resolves host executable paths per target host', () {
      expect(
        ComposeHost.linuxX64.konancExecutable('/kn'),
        p.join('/kn', 'bin', 'konanc'),
      );
      expect(
        ComposeHost.windowsX64.konancExecutable('/kn'),
        p.join('/kn', 'bin', 'konanc.bat'),
      );
    });

    test('rejects linux arm64 early with a precise unsupported-host error', () {
      expect(
        () => ComposeHost.current(
          operatingSystem: 'linux',
          architecture: 'arm64',
        ),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains(
              'compiler and matching JNI/LLVM dependencies, which upstream does not publish',
            ),
          ),
        ),
      );
    });
  });
}
