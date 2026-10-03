import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/doctor_environment_checks.dart';
import 'package:xcross/src/cli/basic/doctor_models.dart';

import '../host_operations_fixtures.dart';

void main() {
  test(
    'doctor consumes selected host and explicit compiler directories',
    () async {
      final tools = <String>[];
      final checks = await DoctorEnvironmentChecks.hostWithSeams(
        hostName: 'fixture-host',
        llvmDirectories: ['/fixture/llvm'],
        locateTool: (name, {accept, extraDirectories = const []}) async {
          tools.add(name);
          expect(extraDirectories, ['/fixture/llvm']);
          return '/fixture/$name';
        },
        iosClang: () async => '/fixture/ios-clang',
        iosLinker: () async => '/fixture/ld64.lld',
        iosLinkerDefect: (_) async => 'fixture linker warning',
        darwinSdk: () async => const DoctorCheck.success('Darwin SDK', 'Ready'),
      );
      expect(tools, ['swift', 'clang++', 'llvm-ar']);
      expect(checks.first.message, contains('fixture-host'));
      expect(
        checks.firstWhere((check) => check.name == 'iOS linker').status,
        DoctorStatus.warning,
      );
    },
  );

  test('doctor reports missing tools without installer effects', () async {
    final checks = await DoctorEnvironmentChecks.hostWithSeams(
      hostName: 'fixture',
      locateTool: (name, {accept, extraDirectories = const []}) async => null,
      iosClang: () async => throw StateError('fixture clang unavailable'),
      iosLinker: () async => '/fixture/linker',
      darwinSdk: () async => const DoctorCheck.failure('Darwin SDK', 'Missing'),
    );
    expect(
      checks.where((check) => check.status == DoctorStatus.failure),
      hasLength(5),
    );
  });

  test('doctor ignores unidentifiable SDK without probing Swift', () async {
    var probes = 0;
    final mismatch = await DoctorEnvironmentChecks.swiftTooOldForSdk(
      '/fixture/bundle',
      sdkPath: (_) => '/fixture/unknown.sdk',
      toolchainIdentity: () async {
        probes++;
        return {};
      },
      log: fixtureLog(),
    );
    expect(mismatch, isNull);
    expect(probes, 0);
  });
}
