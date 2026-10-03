import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/shared/sdk/sdk_install_constants.dart';
import 'package:xcross/src/shared/sdk/sdk_json_file_writer.dart';
import 'package:xcross/src/shared/sdk/sdk_metadata_platform.dart';

final class SdkBundleMetadataWriter<T extends PlatformHostInterface> {
  SdkBundleMetadataWriter(
    this.repository,
    List<SdkMetadataPlatformInterface<T>> metadataPlatforms,
  ) : metadataPlatforms = List.unmodifiable(metadataPlatforms),
      json = SdkJsonFileWriter(repository.host);
  final DarwinSdkRepository<T> repository;
  final List<SdkMetadataPlatformInterface<T>> metadataPlatforms;
  final SdkJsonFileWriter<T> json;
  T get host => repository.host;
  p.Context get _paths => host.paths.context;
  Future<void> materializeSwiftCompatibilityResources(
    String artifactRoot,
  ) async {
    final source = host.fileSystem.file(
      host.paths.ioPath(
        _paths.join(
          artifactRoot,
          sdkSwiftResourcesRelativePath,
          'iphoneos',
          'layouts-arm64.yaml',
        ),
      ),
    );
    if (!source.existsSync() || source.lengthSync() == 0) {
      throw XcrossError(
        'Missing or empty canonical Swift iPhoneOS layout: ${source.path}',
      );
    }
    final destination = host.paths.ioPath(
      _paths.join(
        artifactRoot,
        'Developer',
        'Runtimes',
        'XcodeDefault.xctoolchain',
        'usr',
        'bin',
        'layouts-arm64.yaml',
      ),
    );
    await host.fileSystem
        .directory(_paths.dirname(destination))
        .create(recursive: true);
    await source.copy(destination);
  }

  Future<void> writeSwiftSdkBundleMetadata(String artifactRoot) async {
    final targetMetadata = <String, Object>{};
    final sdk = DarwinSdk(artifactRoot);
    for (final platform in metadataPlatforms) {
      final root = platform.resolveSdkRoot(repository, sdk);
      if (root == null) continue;
      targetMetadata[platform.buildPlatform.swiftSdkTriple] =
          _swiftSdkTargetMetadata(artifactRoot, platform.buildPlatform, root);
    }
    await json.write(_paths.join(artifactRoot, 'swift-sdk.json'), {
      'schemaVersion': '4.0',
      'targetTriples': targetMetadata,
    });
    await json.write(_paths.join(artifactRoot, 'toolset.json'), const {
      'schemaVersion': '1.0',
      'swiftCompiler': {
        'extraCLIOptions': [
          '-Xfrontend',
          '-enable-cross-import-overlays',
          '-use-ld=lld',
        ],
      },
    });
    await json.write(_paths.join(artifactRoot, 'info.json'), const {
      'schemaVersion': '1.0',
      'artifacts': {
        'xcross-darwin': {
          'type': 'swiftSDK',
          'version': '1.0.0',
          'variants': [
            {
              'path': '.',
              'supportedTriples': [
                'x86_64-unknown-linux-gnu',
                'aarch64-unknown-linux-gnu',
                'x86_64-unknown-windows-msvc',
                'aarch64-unknown-windows-msvc',
                'x86_64-apple-macosx',
                'arm64-apple-macosx',
              ],
            },
          ],
        },
      },
    });
  }

  Map<String, Object> _swiftSdkTargetMetadata(
    String artifactRoot,
    IosBuildPlatformInterface target,
    String sdkRoot,
  ) {
    if (!RegExp('[0-9]').hasMatch(_paths.basename(sdkRoot))) {
      throw XcrossError(
        'The extracted Xcode archive did not contain a versioned '
        '${target.platformName} SDK.',
      );
    }
    final relativeSdkRoot = _paths
        .relative(sdkRoot, from: artifactRoot)
        .replaceAll(r'\', '/');
    final toolchainCxx = _paths.join(
      artifactRoot,
      sdkToolchainRelativePath,
      'usr/include/c++/v1',
    );
    final sdkCxx = _paths.join(sdkRoot, 'usr/include/c++/v1');
    final cxxInclude = host.fileSystem.directory(toolchainCxx).existsSync()
        ? '$sdkToolchainRelativePath/usr/include/c++/v1'
        : _paths.relative(sdkCxx, from: artifactRoot).replaceAll(r'\', '/');
    final platformDeveloper =
        'Developer/Platforms/${target.platformName}.platform/Developer';
    return {
      'sdkRootPath': relativeSdkRoot,
      'swiftResourcesPath': sdkSwiftResourcesRelativePath,
      'swiftStaticResourcesPath': sdkSwiftStaticResourcesRelativePath,
      'includeSearchPaths': ['$platformDeveloper/usr/lib', cxxInclude],
      'librarySearchPaths': ['$platformDeveloper/usr/lib'],
      'toolsetPaths': ['toolset.json'],
    };
  }
}
