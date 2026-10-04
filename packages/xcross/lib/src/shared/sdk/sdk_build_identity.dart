import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:crypto/crypto.dart';
import 'package:darwin_sdk_kit/shared/errors/errors.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/sdk/sdk_install_constants.dart';
import 'package:xcross/src/shared/sdk/sdk_metadata_platform.dart';

@internal
final class SdkBuildIdentity<T extends PlatformHostInterface> {
  SdkBuildIdentity(
    this.runner,
    this.repository,
    List<String> swiftBuildTools,
    List<SdkMetadataPlatformInterface<T>> metadataPlatforms,
  ) : swiftBuildTools = List.unmodifiable(swiftBuildTools),
      metadataPlatforms = List.unmodifiable(metadataPlatforms) {
    if (!identical(runner.host, repository.host)) {
      throw ArgumentError(
        'SDK repository and process runner must share a host',
      );
    }
  }
  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> repository;
  final List<String> swiftBuildTools;
  final List<SdkMetadataPlatformInterface<T>> metadataPlatforms;
  T get host => runner.host;
  Log get log => runner.log;
  p.Context get _paths => host.paths.context;
  Future<Map<String, Object>> swiftPmBuildToolchainIdentity({
    required String cCompilerPath,
    required String cxxCompilerPath,
    required String linkerPath,
    required String librarianPath,
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) async {
    final locate = locateTool ?? runner.locateTool;
    final run = runProcess ?? runner.run;
    return {
      for (final name in swiftBuildTools)
        name: await _executableBuildIdentity(name, locate, run),
      'clang': await _fileBuildIdentity(cCompilerPath),
      'clang++': await _fileBuildIdentity(cxxCompilerPath),
      'ld64.lld': await _fileBuildIdentity(linkerPath),
      'librarian': await _fileBuildIdentity(librarianPath),
    };
  }

  Future<Map<String, Object>> sdkBuildIdentity(String sdkRoot) async {
    final files = <String>{
      'info.json',
      'swift-sdk.json',
      'toolset.json',
      hostToolchainStampName,
    };
    final sdk = DarwinSdk(sdkRoot);
    for (final policy in metadataPlatforms) {
      try {
        final target = policy.buildPlatform;
        final platformSdk = repository.iosSdk(sdk, target: target);
        for (final name in const [
          'SDKSettings.json',
          'SDKSettings.plist',
          'System/Library/CoreServices/SystemVersion.plist',
        ]) {
          files.add(
            _paths.relative(_paths.join(platformSdk, name), from: sdkRoot),
          );
        }
      } on DarwinSdkError catch (error) {
        log.logTrace(
          'Could not resolve ${policy.buildPlatform.platformName} SDK identity metadata: $error',
        );
      }
    }
    final metadata = <String, Object>{};
    for (final relative in files.toList()..sort()) {
      final file = host.fileSystem.file(_paths.join(sdkRoot, relative));
      if (!file.existsSync()) continue;
      final stat = file.statSync();
      metadata[relative.replaceAll(r'\', '/')] = {
        'size': stat.size,
        'modified': stat.modified.microsecondsSinceEpoch,
        'changed': stat.changed.microsecondsSinceEpoch,
        'digest': sha256.convert(file.readAsBytesSync()).toString(),
      };
    }
    return {
      'path': _paths.normalize(_paths.absolute(sdkRoot)),
      'metadata': metadata,
    };
  }

  Future<Map<String, Object>> _executableBuildIdentity(
    String name,
    Future<String> Function(String name) locate,
    Future<CapturedProcess> Function(String executable, List<String> arguments)
    run,
  ) async => _executablePathBuildIdentity(name, await locate(name), run);

  Future<Map<String, Object>> _executablePathBuildIdentity(
    String name,
    String path,
    Future<CapturedProcess> Function(String executable, List<String> arguments)
    run,
  ) async {
    final file = host.fileSystem.file(
      host.fileSystem.file(path).resolveSymbolicLinksSync(),
    );
    final result = await run(path, const ['--version']);
    if (result.exitCode != 0) {
      throw StateError('$name --version failed: ${result.stderr.trim()}');
    }
    final output = result.stdout.trim().isEmpty
        ? result.stderr.trim()
        : result.stdout.trim();
    return {
      ...await _fileBuildIdentity(file.path),
      'version': sdkFirstToolchainLine(output),
    };
  }

  Future<Map<String, Object>> _fileBuildIdentity(String path) {
    final file = host.fileSystem.file(
      host.fileSystem.file(path).resolveSymbolicLinksSync(),
    );
    final stat = file.statSync();
    return Future.value({
      'path': file.path,
      'size': stat.size,
      'modified': stat.modified.microsecondsSinceEpoch,
      'changed': stat.changed.microsecondsSinceEpoch,
      'digest': sha256.convert(file.readAsBytesSync()).toString(),
    });
  }
}
