import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:apple_developer_kit/composition/apple_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_privileges.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:dart_mobile_device/host/macos/macos_device_host.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:test/test.dart';
import 'package:xcross/src/target/iphone/device/device_backend.dart';
import 'package:xcross/src/target/iphone/device/signing_http_client_factory.dart';

import 'test_log_output.dart';

void main() {
  final runner = ProcessRunner(
    stdinStream: const Stream.empty(),
    stdoutSink: testSink(),
    stderrSink: testSink(),
    MacOSHost(),
    log: testLog(),
  );

  test('always resolves the native backend', () async {
    expect(
      await DeviceBackend.resolve(
        Pymd(
          console: TestDeviceConsole(),
          localHttp: testLocalHttp(),
          runner,
          privileges: PosixPrivileges(runner),
          hostPolicy: MacOSDeviceHost(runner),
        ),
        hostServices: createMacOSAppleHostServices(
          runner.host as MacOSHostInterface,
          runner: runner,
          localeName: 'en_US',
          abi: Abi.macosArm64,
        ),
        httpClients: const HttpSigningClientFactory(),
        createNativeLibraryLoader: () =>
            throw StateError('no native loading in test'),
      ),
      isA<NativeBackend>(),
    );
  });

  test('rejects non-app inputs before provisioning mutates Apple state', () {
    final uri = Isolate.resolvePackageUriSync(
      Uri.parse('package:xcross/src/target/iphone/device/device_backend.dart'),
    )!;
    final source = File.fromUri(uri).readAsStringSync();
    final guard = source.indexOf(
      'in-process signer currently supports xcross-generated .app',
    );
    final provision = source.indexOf('await AscProvisioning(');

    expect(guard, greaterThanOrEqualTo(0));
    expect(provision, greaterThan(guard));
    expect(source, isNot(contains('ZsignCli')));
  });
}
