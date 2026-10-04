import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:crypto/crypto.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/build/ios_linker_compatibility.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugins.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmDiscovery<T extends PlatformHostInterface> {
  SwiftPmDiscovery({
    required this.hostPolicy,
    required this.sdkIdentity,
    required this.sdkRepository,
    required this.toolchain,
  });
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmSdkIdentity sdkIdentity;
  final DarwinSdkRepository<T> sdkRepository;
  final SwiftPmToolchain<T> toolchain;

  Future<String> incrementalBuildFingerprint({
    required List<IosPlugin> plugins,
    required String flutterXcframework,
    required IosDeploymentTarget deploymentTarget,
    required bool verbose,
    String? toolchainIdentity,
    String? sdkIdentity,
  }) async {
    Digest? result;
    final input = sha256.startChunkedConversion(
      ChunkedConversionSink.withCallback((digests) => result = digests.single),
    );

    void add(String value) {
      input.add(utf8.encode(value));
      input.add(const [0]);
    }

    // v7 invalidated dylibs compiled with availability guards disabled; v8
    // invalidates staged sources compiled before State-wrapper recovery.
    add('xcross-swiftpm-build-v8-state-wrapper-recovery');
    add(objectiveCLinkerSwiftDriverArguments.join('\u0001'));
    add(hostPolicy.fingerprintArguments.join('\u0001'));
    add(deploymentTarget.version);
    add(deploymentTarget.swiftSdkTriple);
    add(verbose.toString());
    final sdk = sdkRepository.current();
    if (toolchainIdentity == null && sdk == null) {
      throw FlutterBuildError(
        'Darwin Swift SDK not found. Run '
        '`xcross sdk install <Xcode.xip>` first.',
      );
    }
    final resolvedToolchainIdentity =
        toolchainIdentity ??
        jsonEncode(
          SwiftPmDiscovery.contentBuildIdentity(
            await toolchain.resolveBuildToolchainIdentity(sdk),
          ),
        );
    add(resolvedToolchainIdentity);
    final resolvedSdkIdentity =
        sdkIdentity ??
        (sdk == null
            ? ''
            : jsonEncode(
                SwiftPmDiscovery.contentBuildIdentity(
                  await this.sdkIdentity.sdkBuildIdentity(sdk.swiftSdkPath),
                ),
              ));
    add(resolvedSdkIdentity);

    Future<void> addTree(String root) async {
      final directory = sdkRepository.host.fileSystem.directory(root);
      if (!directory.existsSync()) {
        add('missing:$root');
        return;
      }
      final files = <File>[];
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) files.add(entity);
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        add(p.relative(file.path, from: root).replaceAll(r'\', '/'));
        input.add(await file.readAsBytes());
        input.add(const [0]);
      }
    }

    for (final plugin
        in plugins.toList()..sort((a, b) => a.name.compareTo(b.name))) {
      add(plugin.name);
      add(plugin.platformDirectoryName);
      await addTree(plugin.swiftPackageDir);
    }
    final frameworkFiles = <File>[];
    await for (final entity
        in sdkRepository.host.fileSystem
            .directory(flutterXcframework)
            .list(recursive: true)) {
      if (entity is File) frameworkFiles.add(entity);
    }
    frameworkFiles.sort((a, b) => a.path.compareTo(b.path));
    for (final file in frameworkFiles) {
      add(
        p.relative(file.path, from: flutterXcframework).replaceAll(r'\', '/'),
      );
      add((await sha256.bind(file.openRead()).first).toString());
    }
    input.close();
    return result!.toString();
  }

  static Object? contentBuildIdentity(Object? value) => switch (value) {
    Map() => {
      for (final entry in value.entries)
        if (!value.containsKey('digest') ||
            (entry.key != 'modified' && entry.key != 'changed'))
          entry.key: SwiftPmDiscovery.contentBuildIdentity(entry.value),
    },
    List() => value.map(SwiftPmDiscovery.contentBuildIdentity).toList(),
    _ => value,
  };
}
