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
              'Compose Kotlin/Native toolchain supports Linux x64 and Windows x64 only; linux arm64 is not supported.',
            ),
          ),
        ),
      );
    });
  });
}
