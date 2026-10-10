import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/shared/errors/errors.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:crypto/crypto.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/swiftpm_binary_fixture.dart';
import 'package:xcross/src/shared/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugins.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_preparer.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_destination_publisher.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/discovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_compiler.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_dependencies.dart';
import 'package:xcross/src/shared/flutter/swiftpm/module_files.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plan_reader.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_fallback.dart';
import 'package:xcross/src/shared/sdk/sdk_install_constants.dart';

import 'swiftpm_test_context.dart';

final _swiftPmRuntime = testSwiftPmRuntime();
final _windowsRuntime = testWindowsSwiftPmRuntime();

final _plugins = GeneratedPluginsPackage(
  _swiftPmRuntime.targetPolicy,
  runner: _swiftPmRuntime.runner,
  sdkRepository: _swiftPmRuntime.sdkRepository,
  toolchain: _swiftPmRuntime.toolchainResolver,
  tools: _swiftPmRuntime.tools,
  hostPolicy: _swiftPmRuntime.hostPolicy,
  artifactFileSystem: _swiftPmRuntime.artifactFileSystem,
  sdkIdentity: _swiftPmRuntime.sdkIdentity,
  publicationCoordinator: _swiftPmRuntime.publicationCoordinator,
  transport: _swiftPmRuntime.transport,
  copyPolicy: _swiftPmRuntime.copyPolicy,
  foundation: _swiftPmRuntime.foundation,
  gatePlatform: _swiftPmRuntime.gatePlatform,
  buildExecution: _swiftPmRuntime.buildExecution,
  dependencyPreparation: _swiftPmRuntime.dependencyPreparation,
  checkout: _swiftPmRuntime.checkout,
  checkoutAttributes: _swiftPmRuntime.checkoutAttributes,
  checkoutManifestNormalizer: _swiftPmRuntime.checkoutManifestNormalizer,
);

@internal
String swiftPath(String path) => p.absolute(path).replaceAll(r'\', '/');

@internal
SwiftPmBinaryArtifactProvenance binaryProvenance(
  String identity,
  String target,
  String checksum,
  String manifestPath,
) {
  final manifest =
      '.binaryTarget(name: "$target", url: "https://example.invalid/archive.zip", checksum: "$checksum")';
  return SwiftPmBinaryProvenance.scanBinaryArtifactProvenance(
    packageIdentity: identity,
    manifestPath: manifestPath,
    manifest: manifest,
  ).single;
}

void main() {
  test(
    'simulator SwiftPM invocation selects simulator target instead of device',
    () {
      final build = _swiftPmRuntime.buildPlan.swiftBuildArguments(
        pluginsDir: '/plugins',
        scratchPath: '/scratch',
        swiftSdksPath: '/sdk',
        iosSdk: '/simulator-sdk',
        flutterFrameworkSlice: '/ios-arm64_x86_64-simulator',
        swiftSdkTriple: 'arm64-apple-ios-simulator',
      );
      expect(
        build,
        containsAllInOrder(['--swift-sdk', 'arm64-apple-ios-simulator']),
      );
      expect(build, isNot(contains('arm64-apple-ios')));
      expect(build, contains('/simulator-sdk'));
      final resolve = _swiftPmRuntime.processPolicy.swiftResolveArguments(
        pluginsDir: '/plugins',
        scratchPath: '/scratch',
        swiftSdksPath: '/sdk',
        toolsetPath: '/toolset',
        swiftSdkTriple: 'arm64-apple-ios-simulator',
      );
      expect(
        resolve,
        containsAllInOrder(['--swift-sdk', 'arm64-apple-ios-simulator']),
      );
    },
  );

  test(
    'Windows manifests import host CRT without package-specific overrides',
    () {
      expect(_windowsRuntime.processPolicy.hostManifestArguments(), [
        '-Xmanifest',
        '-Xfrontend',
        '-Xmanifest',
        '-import-module',
        '-Xmanifest',
        '-Xfrontend',
        '-Xmanifest',
        'CRT',
      ]);
      expect(_swiftPmRuntime.processPolicy.hostManifestArguments(), isEmpty);
    },
  );
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_ios_plugin_package-');
  });

  tearDown(() => tmp.delete(recursive: true));

  /// Creates a fake plugin pub package with an `ios/<name>/Package.swift` and
  /// a `pubspec.yaml` whose `pluginClass` is [pluginClass] (or omitted when
  /// null).
  IosPlugin makePlugin(
    String name, {
    String? pluginClass,
    String packageManifest = '',
    bool sharedDarwinSource = false,
  }) {
    final packageRoot = p.join(tmp.path, name);
    final platformDir = sharedDarwinSource ? 'darwin' : 'ios';
    Directory(
      p.join(packageRoot, platformDir, name),
    ).createSync(recursive: true);
    File(
      p.join(packageRoot, platformDir, name, 'Package.swift'),
    ).writeAsStringSync(packageManifest);

    final pluginSection = pluginClass == null
        ? ''
        : '''
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: $pluginClass
''';
    File(
      p.join(packageRoot, 'pubspec.yaml'),
    ).writeAsStringSync('name: $name\n$pluginSection');

    return IosPlugin(
      fileSystem: _swiftPmRuntime.host.fileSystem,
      name: name,
      packageRoot: packageRoot,
      sharedDarwinSource: sharedDarwinSource,
    );
  }

  group('incremental build fingerprint', () {
    test('ignores restored file timestamps but retains content identity', () {
      Map<String, Object> identity(int timestamp, String digest) => {
        'compiler': {
          'path': '/swift/bin/swiftc',
          'size': 42,
          'modified': timestamp,
          'changed': timestamp,
          'digest': digest,
          'version': '6.3.3',
        },
      };
      final first = SwiftPmDiscovery.contentBuildIdentity(identity(1, 'a'));
      expect(SwiftPmDiscovery.contentBuildIdentity(identity(2, 'a')), first);
      expect(
        SwiftPmDiscovery.contentBuildIdentity(identity(1, 'b')),
        isNot(first),
      );
      expect((first! as Map)['compiler'], {
        'path': '/swift/bin/swiftc',
        'size': 42,
        'digest': 'a',
        'version': '6.3.3',
      });
    });

    test('is stable until a plugin input changes', () async {
      final plugin = makePlugin(
        'stable_plugin',
        packageManifest: 'let package = Package()\n',
      );
      final source =
          File(p.join(plugin.swiftPackageDir, 'Sources', 'Plugin.swift'))
            ..createSync(recursive: true)
            ..writeAsStringSync('let value = 1\n');
      final framework = Directory(p.join(tmp.path, 'Flutter.xcframework'))
        ..createSync();
      File(p.join(framework.path, 'Info.plist')).writeAsStringSync('<plist/>');

      Future<String> fingerprint() =>
          _swiftPmRuntime.discovery.incrementalBuildFingerprint(
            plugins: [plugin],
            flutterXcframework: framework.path,
            deploymentTarget: const IosDeploymentTarget(
              '15.0',
              platform: IPhoneBuildPlatform(),
            ),
            verbose: false,
            toolchainIdentity: 'swift-6.3.3',
            sdkIdentity: 'ios-sdk',
          );

      final first = await fingerprint();
      expect(await fingerprint(), first);
      final frameworkFile = File(p.join(framework.path, 'Info.plist'));
      final modified = frameworkFile.lastModifiedSync();
      frameworkFile.setLastModifiedSync(
        modified.subtract(const Duration(days: 1)),
      );
      expect(await fingerprint(), first);
      frameworkFile.writeAsStringSync('<PLIST/>');
      frameworkFile.setLastModifiedSync(modified);
      expect(await fingerprint(), isNot(first));
      frameworkFile.writeAsStringSync('<plist/>');
      source.writeAsStringSync('let value = 2\n');
      expect(await fingerprint(), isNot(first));
    });

    test('changes with build configuration', () async {
      final plugin = makePlugin('plugin');
      final framework = Directory(p.join(tmp.path, 'Flutter.xcframework'))
        ..createSync();

      Future<String> fingerprint({required bool verbose}) =>
          _swiftPmRuntime.discovery.incrementalBuildFingerprint(
            plugins: [plugin],
            flutterXcframework: framework.path,
            deploymentTarget: const IosDeploymentTarget(
              '15.0',
              platform: IPhoneBuildPlatform(),
            ),
            verbose: verbose,
            toolchainIdentity: 'swift',
            sdkIdentity: 'sdk',
          );

      expect(
        await fingerprint(verbose: true),
        isNot(await fingerprint(verbose: false)),
      );
    });
  });

  group('flutterFrameworkManifest', () {
    test('matches the exact wrapper manifest', () {
      expect(SwiftPmManifest.flutterFrameworkManifest(), '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlutterFramework",
    products: [
        .library(name: "FlutterFramework", targets: ["FlutterFramework"])
    ],
    targets: [
        .binaryTarget(name: "FlutterFramework", path: "Flutter.xcframework")
    ]
)
''');
    });
  });

  group('pluginsManifest', () {
    for (final version in ['13.0', '17.2']) {
      for (final pluginNames in [
        <String>[],
        ['plugin_a', 'plugin_b'],
      ]) {
        test('imports PackageDescription before Package for '
            '${pluginNames.length} plugins on iOS $version', () {
          final plugins = pluginNames.map(makePlugin).toList();
          final frameworkDir = p.join(tmp.path, 'FlutterFramework');
          final manifest = SwiftPmManifest.pluginsManifest(
            plugins,
            frameworkDir,
            deploymentTarget: IosDeploymentTarget(
              version,
              platform: const IPhoneBuildPlatform(),
            ),
          );

          expect(
            manifest,
            startsWith(
              '// swift-tools-version: 5.9\n'
              'import PackageDescription\n\n'
              'let package = Package(',
            ),
          );
          expect(
            'import PackageDescription'.allMatches(manifest),
            hasLength(1),
          );
          expect(manifest, contains('.iOS("$version")'));
          expect(
            '.package('.allMatches(manifest),
            hasLength(plugins.length + 1),
          );
          expect(
            '.product('.allMatches(manifest),
            hasLength(plugins.length + 1),
          );
          expect(
            manifest,
            contains(
              '.package(name: "FlutterFramework", '
              'path: "${swiftPath(frameworkDir)}")',
            ),
          );
          expect(
            manifest,
            contains(
              '.product(name: "FlutterFramework", '
              'package: "FlutterFramework")',
            ),
          );
          for (final plugin in plugins) {
            expect(
              manifest,
              contains(
                '.package(name: "${plugin.name}", '
                'path: "${swiftPath(plugin.swiftPackageDir)}")',
              ),
            );
            expect(
              manifest,
              contains(
                '.product(name: "${plugin.name.replaceAll('_', '-')}", '
                'package: "${plugin.name}")',
              ),
            );
          }
        });
      }
    }

    test('includes every plugin package dependency and hyphenated product', () {
      final pluginA = makePlugin('plugin_a', pluginClass: 'PluginA');
      final pluginB = makePlugin('plugin_b');
      final frameworkDir = p.join(tmp.path, 'FlutterFramework');

      const target = IosDeploymentTarget(
        '15.6',
        platform: IPhoneBuildPlatform(),
      );
      final manifest = SwiftPmManifest.pluginsManifest(
        [pluginA, pluginB],
        frameworkDir,
        deploymentTarget: target,
      );

      expect(manifest, contains('name: "FlutterPluginsGenerated"'));
      expect(manifest, contains('.iOS("15.6")'));
      expect(manifest, isNot(contains('-disable-availability-checking')));
      expect(manifest, isNot(contains('.iOS("13.0")')));
      expect(
        manifest,
        contains(
          '.library(name: "FlutterPluginsGenerated", type: .dynamic, '
          'targets: ["FlutterPluginsGenerated"])',
        ),
      );
      expect(manifest, contains('.package(name: "FlutterFramework", path:'));
      expect(manifest, contains('.package(name: "plugin_a", path:'));
      expect(manifest, contains('.package(name: "plugin_b", path:'));
      expect(
        manifest,
        contains('.product(name: "plugin-a", package: "plugin_a")'),
      );
      expect(
        manifest,
        contains('.product(name: "plugin-b", package: "plugin_b")'),
      );
      expect(
        manifest,
        contains(
          '.product(name: "FlutterFramework", package: "FlutterFramework")',
        ),
      );
    });

    test('paths are forward-slash safe', () {
      final pluginA = makePlugin('plugin_a');
      final frameworkDir = p.join(tmp.path, 'FlutterFramework');

      final manifest = SwiftPmManifest.pluginsManifest(
        [pluginA],
        frameworkDir,
        deploymentTarget: const IosDeploymentTarget(
          '15.0',
          platform: IPhoneBuildPlatform(),
        ),
      );

      expect(manifest, isNot(contains(r'\')));
    });
  });

  group('normalizeLinkerFlags', () {
    test('normalizes SwiftPM Wl linker flags', () {
      expect(
        SwiftPmHostSourceNormalizer.normalizeLinkerFlags(
          '.unsafeFlags(["-Wl,-undefined,dynamic_lookup"])',
        ),
        '.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", '
        '"dynamic_lookup"])',
      );
      expect(
        SwiftPmHostSourceNormalizer.normalizeLinkerFlags(
          '.unsafeFlags(["-O3", "-Wl,-rpath,@loader_path"])',
        ),
        '.unsafeFlags(["-O3", "-Xlinker", "-rpath", "-Xlinker", '
        '"@loader_path"])',
      );

      const escaped = r'.unsafeFlags(["-Wl,-rpath,\"quoted\""])';
      expect(
        SwiftPmHostSourceNormalizer.normalizeLinkerFlags(escaped),
        escaped,
      );
    });
  });

  group('package manifest discovery', () {
    test('uses Git index instead of traversing deep checkout assets', () async {
      final package = Directory(p.join(tmp.path, 'AppAuth-iOS'))
        ..createSync(recursive: true);
      late List<String> arguments;

      final files = await _swiftPmRuntime.binaryProvenance
          .trackedPackageManifestFiles(
            package.path,
            runProcess: (executable, args) async {
              expect(executable, 'git');
              arguments = args;
              return const CapturedProcess(
                0,
                'Package.swift\u0000Nested/Package@swift-6.0.swift\u0000',
                '',
              );
            },
          );

      expect(
        arguments,
        containsAllInOrder([
          '-c',
          'core.longpaths=true',
          '-C',
          package.path,
          'ls-files',
          '-z',
        ]),
      );
      expect(files.map((file) => p.relative(file.path, from: package.path)), [
        p.join('Nested', 'Package@swift-6.0.swift'),
        'Package.swift',
      ]);
    });

    test('reports Git index failures for existing checkout roots', () async {
      await expectLater(
        _swiftPmRuntime.binaryProvenance.trackedPackageManifestFiles(
          tmp.path,
          runProcess: (executable, arguments) async =>
              const CapturedProcess(128, '', 'not a repository'),
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            contains('not a repository'),
          ),
        ),
      );
    });
  });

  group('normalizeHostManifest', () {
    test('finds dependency products that may emit Swift headers', () {
      expect(
        SwiftPmManifestDependencies.dependencyProductNames('''
.product(name: "AlphaKit", package: "alpha-kit"),
.product(name: "beta-kit", package: "beta_kit"),
'''),
        {'AlphaKit', 'beta-kit'},
      );
    });

    test('inserts CRT and ucrt before MSVCRT', () {
      const input = '''
#if canImport(Darwin)
import Darwin.C
#elseif canImport(Glibc)
import Glibc
#elseif canImport(MSVCRT)
import MSVCRT
#endif
''';
      final out = _windowsRuntime.checkoutManifestNormalizer.policy
          .normalizeHostManifest(input);
      expect(
        out,
        contains(
          '#elseif canImport(CRT)\n'
          'import CRT\n'
          '#elseif canImport(ucrt)\n'
          'import ucrt\n'
          '#elseif canImport(MSVCRT)\n'
          'import MSVCRT',
        ),
      );
      expect(out, isNot(contains('import Darwin.C\n#elseif canImport(CRT)')));
    });

    test('handles CRLF MSVCRT import blocks', () {
      const input =
          '#elseif canImport(MSVCRT)\r\n'
          'import MSVCRT';
      expect(
        _windowsRuntime.checkoutManifestNormalizer.policy.normalizeHostManifest(
          input,
        ),
        contains('import CRT\n'),
      );
    });

    test('exposes package graph entries on cross hosts', () {
      const input = '''
#if os(macOS)
let unrelated = true
#endif
func packageDependencies() -> [Package.Dependency] {
  #if os(macOS)
  return [.package(url: dependencyURL, from: "1.0.0")]
  #endif
}
''';
      final normalized = _swiftPmRuntime.sourceNormalizer.normalizeHostManifest(
        input,
      );
      expect(normalized, startsWith('#if os(macOS)\nlet unrelated'));
      expect(
        normalized,
        contains('return [.package(url: dependencyURL, from: "1.0.0")]'),
      );
      expect('#if os(macOS)'.allMatches(normalized), hasLength(1));
    });

    test('drops Foundation String(cString:encoding:) in manifests', () {
      const input =
          'if let env = env, String(cString: env, encoding: .utf8) == "1"';
      expect(
        _swiftPmRuntime.sourceNormalizer.normalizeHostManifest(input),
        'if let env = env, String(cString: env) == "1"',
      );
    });

    test('normalization is idempotent', () {
      const input = '''
#elseif canImport(MSVCRT)
import MSVCRT
''';
      final normalized = _windowsRuntime.checkoutManifestNormalizer.policy
          .normalizeHostManifest(input);
      expect(
        _windowsRuntime.checkoutManifestNormalizer.policy.normalizeHostManifest(
          normalized,
        ),
        normalized,
      );
      expect('import CRT'.allMatches(normalized), hasLength(1));
    });

    test('preserves source fallback product and target names', () {
      const input = '''
var products: [Product] = [.library(name: "PublicSDK", targets: ["PublicSDK"])]
var targets: [Target] = [.binaryTarget(name: "PublicSDK", url: "SDK.xcframework.zip", checksum: "abc")]
if getenv("EXPERIMENTAL_SPM_BUILDS") != nil {
    targets.append(.target(name: "SourceSDK", path: "Sources"))
    products.append(.library(name: "SourceProduct", type: .dynamic, targets: ["SourceSDK"]))
}
''';
      final normalized = _swiftPmRuntime.sourceNormalizer.normalizeHostManifest(
        input,
      );
      expect(
        normalized,
        contains(
          'if getenv("EXPERIMENTAL_SPM_BUILDS") != nil {\n'
          '    products.removeAll()\n'
          '    targets.removeAll()',
        ),
      );
      expect(
        normalized,
        contains('.target(name: "SourceSDK", path: "Sources")'),
      );
      expect(
        normalized,
        contains(
          '.library(name: "SourceProduct", type: .dynamic, '
          'targets: ["SourceSDK"])',
        ),
      );
      expect(
        _swiftPmRuntime.sourceNormalizer.normalizeHostManifest(normalized),
        normalized,
      );
    });

    for (final name in ['AlphaKit', 'BetaKit']) {
      test('leaves $name target and package declarations unchanged', () {
        final input =
            '''
let package = Package(
  name: "$name",
  platforms: [.iOS(.v12)],
  targets: [
    .target(
    name: "$name",
    path: "$name/Sources",
    cSettings: []
    )
  ]
)
''';
        expect(
          _swiftPmRuntime.sourceNormalizer.normalizeHostManifest(input),
          input,
        );
      });
    }

    test('isolates the graph in the block gated on the variable', () {
      const input = '''
var products: [Product] = []
if true {
    products.append(.library(name: "AlphaKit", targets: ["AlphaKit"]))
}
var targets: [Target] = [.binaryTarget(name: "BetaKit", path: "BetaKit.xcframework")]
if getenv("GAMMA_FLAG") != nil {
    targets.append(.target(name: "BetaSource"))
    products.append(.library(name: "BetaKit", targets: ["BetaSource"]))
}
''';
      expect(
        SwiftPmHostSourceNormalizer.isolateEnvironmentGatedGraph(
          input,
          'GAMMA_FLAG',
        ),
        input.replaceFirst(
          'if getenv("GAMMA_FLAG") != nil {',
          'if getenv("GAMMA_FLAG") != nil {\n'
              '    products.removeAll()\n'
              '    targets.removeAll()',
        ),
      );
    });

    test('isolates the graph gated through a variable binding', () {
      const input = '''
products.append(.library(name: "AlphaKit", targets: ["AlphaKit"]))
let gamma = getenv("GAMMA_FLAG")
#if os(Linux)
let unrelated = true
#endif
if let gamma, String(cString: gamma) == "1" {
    products.append(.library(name: "BetaKit", targets: ["BetaSource"]))
}
''';
      expect(
        SwiftPmHostSourceNormalizer.isolateEnvironmentGatedGraph(
          input,
          'GAMMA_FLAG',
        ),
        input.replaceFirst(
          '== "1" {',
          '== "1" {\n'
              '    products.removeAll()\n'
              '    targets.removeAll()',
        ),
      );
    });

    test('isolates the source fallback block after unrelated products', () {
      const input = '''
var products: [Product] = []
if true {
    products.append(.library(name: "AlphaKit", targets: ["AlphaKit"]))
}
if getenv("EXPERIMENTAL_SPM_BUILDS") != nil {
    products.append(.library(name: "BetaKit", targets: ["BetaSource"]))
}
''';
      expect(
        _swiftPmRuntime.sourceNormalizer.normalizeHostManifest(input),
        input.replaceFirst(
          'if getenv("EXPERIMENTAL_SPM_BUILDS") != nil {',
          'if getenv("EXPERIMENTAL_SPM_BUILDS") != nil {\n'
              '    products.removeAll()\n'
              '    targets.removeAll()',
        ),
      );
    });

    test('leaves manifests without a gated product block unchanged', () {
      const otherFlag =
          'products.append(.library(name: "AlphaKit", targets: ["AlphaKit"]))\n'
          'let flag = getenv("OTHER_FLAG")\n'
          'if flag != nil {\n'
          '    products.append(.library(name: "BetaKit", targets: []))\n'
          '}\n';
      const targetOnly =
          'products.append(.library(name: "AlphaKit", targets: ["AlphaKit"]))\n'
          'if getenv("GAMMA_FLAG") != nil {\n'
          '    targets.append(.target(name: "BetaKit"))\n'
          '}\n';
      const commented =
          '// if getenv("GAMMA_FLAG") != nil { products.append(x) }\n'
          'products.append(.library(name: "AlphaKit", targets: []))\n';
      for (final input in [otherFlag, targetOnly, commented]) {
        expect(
          SwiftPmHostSourceNormalizer.isolateEnvironmentGatedGraph(
            input,
            'GAMMA_FLAG',
          ),
          input,
        );
      }
    });

    test('still normalizes linker flags', () {
      expect(
        _swiftPmRuntime.sourceNormalizer.normalizeHostManifest(
          '.unsafeFlags(["-Wl,-rpath,@loader_path"])',
        ),
        '.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path"])',
      );
    });
  });

  group('normalizeHostSwiftSource', () {
    test('leaves preview declarations and every other source untouched', () {
      const input = '''
let before = true
@available(iOS 17.0, *)
#Preview(
  "Nested"
) {
  Container {
    Button("Go") { run() }
  }
}
#Preview { OtherView() }
#Previewable @State var count = 0
let after = true
''';

      expect(
        SwiftPmHostSourceNormalizer.normalizeHostSwiftSource(input),
        input,
      );
    });

    test('imports fallback Swift modules before the compatibility parent', () {
      const input = '''
@_spi(Private) import PublicSDK
import PublicSDK._Hybrid
let value = PublicAPI()
''';
      final output = SwiftPmHostSourceNormalizer.normalizeHostSwiftSource(
        input,
        fallbackSwiftModules: const {
          'PublicSDK': ['SwiftImpl'],
        },
      );

      expect(output, '''
@_spi(Private) import SwiftImpl
@_spi(Private) import PublicSDK
import PublicSDK._Hybrid
let value = PublicAPI()
''');
      expect(
        SwiftPmHostSourceNormalizer.normalizeHostSwiftSource(
          output,
          fallbackSwiftModules: const {
            'PublicSDK': ['SwiftImpl'],
          },
        ),
        output,
      );
    });
  });

  group('normalizeHostSwiftTree', () {
    test(
      'injects fallback imports across a tree and skips manifests',
      () async {
        final root = p.join(
          tmp.path,
          'scratch',
          'checkouts',
          'generic-package',
        );
        final source = File(p.join(root, 'Sources', 'Feature', 'Widget.swift'))
          ..createSync(recursive: true)
          ..writeAsStringSync('import PublicSDK\nlet before = 1\n');
        final manifest = File(p.join(root, 'Package.swift'))
          ..writeAsStringSync('import PublicSDK\n');
        final versionedManifest = File(p.join(root, 'Package@swift-6.0.swift'))
          ..writeAsStringSync('import PublicSDK\n');

        await _swiftPmRuntime.sourceNormalizer.normalizeHostSwiftTree(
          p.join(tmp.path, 'scratch', 'checkouts'),
          fallbackSwiftModules: const {
            'PublicSDK': ['SwiftImpl'],
          },
        );

        expect(source.readAsStringSync(), contains('let before = 1'));
        expect(source.readAsStringSync(), contains('import SwiftImpl\n'));
        // Package.swift and its versioned siblings are never rewritten: they
        // execute on the host during resolution, so a rewrite here would
        // apply too late to matter and could not be re-parsed as a manifest.
        expect(manifest.readAsStringSync(), isNot(contains('SwiftImpl')));
        expect(
          versionedManifest.readAsStringSync(),
          isNot(contains('SwiftImpl')),
        );
      },
    );

    test('is a no-op tree walk without a fallback module', () async {
      final root = p.join(tmp.path, 'tree');
      final source = File(p.join(root, 'A', 'Source.swift'))
        ..createSync(recursive: true)
        ..writeAsStringSync('let value = 1\n');
      final before = source.readAsBytesSync();

      await _swiftPmRuntime.sourceNormalizer.normalizeHostSwiftTree(root);

      expect(source.readAsBytesSync(), before);
    });
  });

  group('binary fallback compatibility module', () {
    void write(String relative, String contents) {
      final file = File(p.join(tmp.path, relative));
      file.createSync(recursive: true);
      file.writeAsStringSync(contents);
    }

    const manifest = '''
var products: [Product] = [
    .library(name: "PublicSDK", targets: ["BinaryArtifact"]),
]
var targets: [Target] = [
    .binaryTarget(name: "BinaryArtifact", url: "SDK.zip", checksum: "abc"),
]
if getenv("CROSS_HOST_SOURCE") != nil {
    products.removeAll()
    targets.removeAll()
    products.append(.library(name: "SourceProduct", targets: ["RootImpl"]))
    targets.append(contentsOf: [
        .target(name: "HeaderImpl", path: "Sources/ObjC", publicHeadersPath: "Public"),
        .target(name: "SwiftImpl", dependencies: ["HeaderImpl"], path: "Sources/Swift"),
        .target(name: "RootImpl", dependencies: ["SwiftImpl"], path: "Sources/Root"),
    ])
}
''';

    test('aliases consumed products in a detached manifest', () {
      final output = _swiftPmRuntime.sourceFallback.aliasBinaryFallbackProducts(
        manifest,
        consumedProducts: {'PublicSDK', 'SourceProduct'},
      );
      expect(
        output,
        contains(
          '    products.append(.library(name: "PublicSDK", '
          'targets: ["RootImpl"]))\n}',
        ),
      );
      expect(RegExp('name: "SourceProduct"').allMatches(output), hasLength(1));
      expect(
        _swiftPmRuntime.sourceFallback.aliasBinaryFallbackProducts(
          manifest,
          consumedProducts: const {},
        ),
        manifest,
      );
    });

    test('emits consumed module without renaming fallback topology', () async {
      write(
        'Sources/ObjC/Public/module.modulemap',
        'module HeaderSurface { umbrella header "PublicSDK.h" export * }',
      );
      write('Sources/ObjC/Public/PublicSDK.h', '// public\n');
      write('Sources/ObjC/Hybrid/PrivateAPI.h', '// hybrid\n');
      write('Sources/Swift/Implementation.swift', 'public struct API {}\n');
      write('Sources/Resources/PublicSDK.modulemap', '''
framework module PublicSDK {
  umbrella header "PublicSDK.h"
  export *
  explicit module _Hybrid {
    header "PrivateAPI.h"
    export *
  }
}
''');

      final fallbackSwiftModules = <String, List<String>>{};
      final output = await _swiftPmRuntime.sourceFallback
          .synthesizeBinaryFallbackCompatibility(
            manifest,
            packageDir: tmp.path,
            consumedProducts: {'PublicSDK'},
            fallbackSwiftModules: fallbackSwiftModules,
          );

      expect(fallbackSwiftModules, {
        'PublicSDK': ['SwiftImpl'],
      });
      expect(
        output,
        contains('.library(name: "SourceProduct", targets: ["RootImpl"])'),
      );
      expect(output, contains('.target(name: "HeaderImpl"'));
      expect(
        output,
        contains('.library(name: "PublicSDK", targets: ["_xcross_PublicSDK"])'),
      );
      expect(
        output,
        contains(
          '.target(name: "_xcross_PublicSDK", dependencies: '
          '["RootImpl", "SwiftImpl", "HeaderImpl"]',
        ),
      );
      expect(
        File(
          p.join(
            tmp.path,
            '.xcross',
            '_xcross_PublicSDK',
            'include',
            'PublicSDK.h',
          ),
        ).readAsStringSync(),
        '@import HeaderSurface;\n'
        '#if __has_include("SwiftImpl-Swift.h")\n'
        '#import "SwiftImpl-Swift.h"\n'
        '#elif !defined(__swift__)\n'
        '@import SwiftImpl;\n'
        '#endif\n',
      );
      final moduleMap = File(
        p.join(
          tmp.path,
          '.xcross',
          '_xcross_PublicSDK',
          'include',
          'module.modulemap',
        ),
      ).readAsStringSync();
      expect(moduleMap, contains('module PublicSDK {'));
      expect(moduleMap, contains('  export _Hybrid\n'));
      expect(moduleMap, contains('explicit module _Hybrid'));
      // A nested module is compiled on its own, so it does not inherit what
      // the parent's header pulled in. Its headers name the same types, so
      // it needs the shim header too.
      expect(
        moduleMap,
        contains('explicit module _Hybrid {\n    header "PublicSDK.h"'),
      );
      expect(
        moduleMap,
        contains(
          swiftPath(p.join(tmp.path, 'Sources/ObjC/Hybrid/PrivateAPI.h')),
        ),
      );

      final regenerated = await _swiftPmRuntime.sourceFallback
          .synthesizeBinaryFallbackCompatibility(
            output,
            packageDir: tmp.path,
            consumedProducts: {'PublicSDK'},
          );
      expect(regenerated, output);
      expect(
        File(
          p.join(
            tmp.path,
            '.xcross',
            '_xcross_PublicSDK',
            'include',
            'PublicSDK.h',
          ),
        ).readAsStringSync(),
        '@import HeaderSurface;\n'
        '#if __has_include("SwiftImpl-Swift.h")\n'
        '#import "SwiftImpl-Swift.h"\n'
        '#elif !defined(__swift__)\n'
        '@import SwiftImpl;\n'
        '#endif\n',
      );

      final retainedName = manifest.replaceFirst('SourceProduct', 'PublicSDK');
      final retained = await _swiftPmRuntime.sourceFallback
          .synthesizeBinaryFallbackCompatibility(
            retainedName,
            packageDir: tmp.path,
            consumedProducts: {'PublicSDK'},
          );
      expect(
        await _swiftPmRuntime.sourceFallback
            .synthesizeBinaryFallbackCompatibility(
              retained,
              packageDir: tmp.path,
              consumedProducts: {'PublicSDK'},
            ),
        retained,
      );
      expect(
        await _swiftPmRuntime.sourceFallback
            .synthesizeBinaryFallbackCompatibility(
              retained.replaceFirst(
                '"_xcross_PublicSDK"]',
                '"_xcross_PublicSDK", "_xcross_PublicSDK"]',
              ),
              packageDir: tmp.path,
              consumedProducts: {'PublicSDK'},
            ),
        retained,
      );
    });

    test('does nothing when fallback already emits expected module', () async {
      write(
        'Sources/ObjC/Public/module.modulemap',
        'module PublicSDK { umbrella header "PublicSDK.h" export * }',
      );
      write('Sources/ObjC/Public/PublicSDK.h', '// public\n');

      final output = await _swiftPmRuntime.sourceFallback
          .synthesizeBinaryFallbackCompatibility(
            manifest,
            packageDir: tmp.path,
            consumedProducts: {'PublicSDK'},
          );

      expect(output, manifest);
      expect(Directory(p.join(tmp.path, '.xcross')).existsSync(), isFalse);
    });

    test('fails instead of guessing an ambiguous fallback product', () async {
      final ambiguous = manifest.replaceFirst(
        'products.append(.library(name: "SourceProduct", targets: ["RootImpl"]))',
        'products.append(.library(name: "SourceA", targets: ["RootImpl"]))\n'
            '    products.append(.library(name: "SourceB", targets: ["RootImpl"]))',
      );

      await expectLater(
        _swiftPmRuntime.sourceFallback.synthesizeBinaryFallbackCompatibility(
          ambiguous,
          packageDir: tmp.path,
          consumedProducts: {'PublicSDK'},
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.toString(),
            'message',
            contains('fallback product is ambiguous'),
          ),
        ),
      );
    });
  });

  group('checkout fallback reconcile', () {
    const manifest = '''
var products: [Product] = [
    .library(name: "PublicSDK", targets: ["BinaryArtifact"]),
]
var targets: [Target] = [
    .binaryTarget(name: "BinaryArtifact", url: "SDK.zip", checksum: "abc"),
]
if getenv("CROSS_HOST_SOURCE") != nil {
    products.removeAll()
    targets.removeAll()
    products.append(.library(name: "SourceProduct", targets: ["SwiftImpl"]))
    targets.append(contentsOf: [
        .target(name: "HeaderImpl", path: "Sources/ObjC", publicHeadersPath: "Public"),
        .target(name: "SwiftImpl", dependencies: ["HeaderImpl"], path: "Sources/Swift"),
    ])
}
let package = Package(name: "dependency", products: products, targets: targets)
''';

    test('writes fallback files that match the compiled manifest text '
        'without rewriting Package.swift', () async {
      final outputDir = p.join(tmp.path, 'out');
      final scratch = p.join(tmp.path, 'scratch');
      final package = p.join(scratch, 'checkouts', 'dependency');
      void write(String relative, String contents) =>
          File(p.join(package, relative))
            ..createSync(recursive: true)
            ..writeAsStringSync(contents);
      write('Package.swift', manifest);
      write('Sources/ObjC/Public/PublicSDK.h', '// public\n');
      write('Sources/Swift/Implementation.swift', 'struct API {}\n');
      write(
        'Sources/Resources/PublicSDK.modulemap',
        'framework module PublicSDK { umbrella header "PublicSDK.h" }\n',
      );
      final manifestFile = File(p.join(package, 'Package.swift'));
      final stamp = manifestFile.lastModifiedSync();

      final reconciled = await _swiftPmRuntime.workspaceStager
          .reconcileCheckoutFallbacks(
            outputDir: outputDir,
            scratchPath: scratch,
            consumedProducts: {
              'dependency': {'PublicSDK'},
            },
          );
      expect(manifestFile.readAsStringSync(), manifest);
      expect(manifestFile.lastModifiedSync(), stamp);
      expect(reconciled.consumedProducts, {
        'dependency': {'PublicSDK'},
      });
      expect(reconciled.swiftModules, isTrue);

      final text =
          await SwiftPmManifestCompiler(
            fileSystem: _swiftPmRuntime.artifactFileSystem,
            policy: _swiftPmRuntime.checkoutManifestNormalizer.policy,
            sourceNormalizer: _swiftPmRuntime.sourceNormalizer,
            run: (_, _) async => 0,
          ).rewrite(
            manifest,
            manifestPath: manifestFile.path,
            identity: 'dependency',
            configuration: SwiftPmManifestCompilerConfiguration(
              compiler: 'swiftc',
              cacheRoot: tmp.path,
              policy: 'policy',
              consumedProducts: const {
                'dependency': ['PublicSDK'],
              },
            ),
          );
      final synthetic = RegExp(
        'path: "([^"]*_xcross_PublicSDK[^"]*)"',
      ).firstMatch(text);
      expect(synthetic, isNotNull);
      final syntheticPath = synthetic!.group(1)!;
      expect(
        Directory(
          p.isAbsolute(syntheticPath)
              ? syntheticPath
              : p.join(package, syntheticPath),
        ).existsSync(),
        isTrue,
      );

      final again = await _swiftPmRuntime.workspaceStager
          .reconcileCheckoutFallbacks(
            outputDir: outputDir,
            scratchPath: scratch,
            consumedProducts: reconciled.consumedProducts,
          );
      expect(again.swiftModules, isFalse);
      expect(manifestFile.lastModifiedSync(), stamp);
    });
  });

  group('binary fallback through a mapped artifact filesystem', () {
    const manifest = '''
var products: [Product] = [
    .library(name: "FallbackKit", targets: ["FallbackKitBinary"]),
]
var targets: [Target] = [
    .binaryTarget(name: "FallbackKitBinary", url: "FallbackKit.zip", checksum: "abc"),
]
if getenv("CROSS_HOST_SOURCE") != nil {
    products.removeAll()
    targets.removeAll()
    products.append(.library(name: "FallbackKit", targets: ["FallbackKitSwift"]))
    targets.append(contentsOf: [
        .target(name: "FallbackKitObjC", path: "Sources", sources: ["FallbackKitObjC"], publicHeadersPath: "FallbackKitObjC/Public"),
        .target(name: "FallbackKitSwift", dependencies: ["FallbackKitObjC"], path: "Sources/FallbackKitSwift", exclude: ["Skipped"]),
    ])
}
''';

    late String logical;
    late String physical;
    late AliasedSwiftPmArtifactFileSystem fileSystem;

    setUp(() {
      logical = p.join(tmp.path, 'logical', 'FallbackKit');
      physical = p.join(tmp.path, 'physical', 'FallbackKit');
      fileSystem = AliasedSwiftPmArtifactFileSystem(
        logicalRoot: logical,
        physicalRoot: physical,
      );
      void write(String relative, String contents) {
        File(p.join(physical, relative))
          ..createSync(recursive: true)
          ..writeAsStringSync(contents);
      }

      write('Sources/FallbackKitObjC/Public/FallbackKitObjC.h', '// public\n');
      write(
        'Sources/FallbackKitObjC/Hybrid/FallbackKitPrivate.h',
        '// hybrid\n',
      );
      write('Sources/FallbackKitSwift/Kit.swift', 'public struct Kit {}\n');
      write('Sources/FallbackKitSwift/Skipped/Old.swift', 'struct Old {}\n');
      write('Sources/Resources/FallbackKit.modulemap', '''
framework module FallbackKit {
  umbrella header "FallbackKitObjC.h"
  export *
  explicit module _Hybrid {
    header "FallbackKitPrivate.h"
    export *
  }
}
''');
    });

    test(testOn: '!windows', 'resolves module references to logical paths', () {
      final moduleFiles = SwiftPmModuleFiles(fileSystem: fileSystem);
      expect(
        moduleFiles.resolveModuleReference(
          logical,
          'FallbackKitObjC.h',
          directory: false,
        ),
        p.join(logical, 'Sources/FallbackKitObjC/Public/FallbackKitObjC.h'),
      );
      expect(
        moduleFiles.absoluteNestedModuleHeaders(
          logical,
          'module _Hybrid { header "FallbackKitPrivate.h" }',
        ),
        contains(
          swiftPath(
            p.join(
              logical,
              'Sources/FallbackKitObjC/Hybrid/FallbackKitPrivate.h',
            ),
          ),
        ),
      );
    });

    test(
      'synthesizes a nested public header module from logical paths',
      () async {
        final runtime = _swiftPmRuntime;
        final fallback = SwiftPmSourceFallback<MacOSHost>(
          filesystem: SwiftPmFilesystem(
            host: runtime.host,
            runner: runtime.runner,
            artifactFileSystem: fileSystem,
          ),
          moduleFiles: SwiftPmModuleFiles(fileSystem: fileSystem),
        );
        final fallbackSwiftModules = <String, List<String>>{};

        final output = await fallback.synthesizeBinaryFallbackCompatibility(
          manifest,
          packageDir: logical,
          consumedProducts: {'FallbackKit'},
          fallbackSwiftModules: fallbackSwiftModules,
        );

        expect(fallbackSwiftModules, {
          'FallbackKit': ['FallbackKitSwift'],
        });
        expect(output, contains('.target(name: "_xcross_FallbackKit"'));
        final include = p.join(
          physical,
          '.xcross',
          '_xcross_FallbackKit',
          'include',
        );
        expect(
          File(p.join(include, 'FallbackKit.h')).readAsStringSync(),
          startsWith('@import FallbackKitObjC;\n'),
        );
        final moduleMap = File(
          p.join(include, 'module.modulemap'),
        ).readAsStringSync();
        expect(
          moduleMap,
          contains(
            swiftPath(
              p.join(
                logical,
                'Sources/FallbackKitObjC/Hybrid/FallbackKitPrivate.h',
              ),
            ),
          ),
        );
        expect(moduleMap, isNot(contains(swiftPath(physical))));
        expect(Directory(p.join(logical, '.xcross')).existsSync(), isFalse);
      },
    );

    test('tree copies contain and exclude by logical paths', () async {
      final filesystem = SwiftPmFilesystem(
        host: _swiftPmRuntime.host,
        runner: _swiftPmRuntime.runner,
        artifactFileSystem: fileSystem,
      );
      final staged = p.join(logical, 'Staged');
      await filesystem.syncDirectory(logical, staged);
      expect(
        File(
          p.join(physical, 'Staged', 'Sources/FallbackKitSwift/Kit.swift'),
        ).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(physical, 'Staged', 'Staged')).existsSync(),
        isFalse,
      );

      final copied = p.join(tmp.path, 'logical', 'Copied');
      await filesystem.copyResolvedArtifactTree(
        p.join(logical, 'Sources'),
        copied,
      );
      expect(
        File(p.join(copied, 'FallbackKitSwift', 'Kit.swift')).existsSync(),
        isTrue,
      );
    });
  });

  group('binary artifact provenance', () {
    test('keeps package and target identity when matching artifacts', () {
      final first = _swiftPmRuntime.binaryProvenance
          .matchBinaryArtifactProvenance(
            artifactPath: p.join('scratch', 'artifacts', 'one', 'SharedBinary'),
            artifactsRoot: p.join('scratch', 'artifacts'),
            provenance: [
              binaryProvenance(
                'one',
                'SharedBinary',
                'a' * 64,
                'one/Package.swift',
              ),
              binaryProvenance(
                'two',
                'SharedBinary',
                'b' * 64,
                'two/Package.swift',
              ),
            ],
          );
      final second = _swiftPmRuntime.binaryProvenance
          .matchBinaryArtifactProvenance(
            artifactPath: p.join('scratch', 'artifacts', 'two', 'SharedBinary'),
            artifactsRoot: p.join('scratch', 'artifacts'),
            provenance: [
              binaryProvenance(
                'one',
                'SharedBinary',
                'a' * 64,
                'one/Package.swift',
              ),
              binaryProvenance(
                'two',
                'SharedBinary',
                'b' * 64,
                'two/Package.swift',
              ),
            ],
          );

      expect(first?.manifestPath, 'one/Package.swift');
      expect(second?.manifestPath, 'two/Package.swift');
    });

    test('matches SwiftPM layout case-insensitively on Windows', () {
      final match = _windowsRuntime.binaryProvenance
          .matchBinaryArtifactProvenance(
            artifactPath: p.join('artifacts', 'PACKAGE', 'target'),
            artifactsRoot: 'artifacts',
            provenance: [
              binaryProvenance('Package', 'Target', 'A' * 64, 'Package.swift'),
            ],
          );

      expect(match?.packageIdentity, 'Package');
    });

    test('rejects ambiguous package identity and dynamic targets', () {
      final duplicate = binaryProvenance(
        'package',
        'Target',
        'a' * 64,
        'Package.swift',
      );
      expect(
        _swiftPmRuntime.binaryProvenance.matchBinaryArtifactProvenance(
          artifactPath: p.join('artifacts', 'package', 'Target'),
          artifactsRoot: 'artifacts',
          provenance: [duplicate, duplicate],
        ),
        isNull,
      );
      expect(
        SwiftPmBinaryProvenance.scanBinaryArtifactProvenance(
          packageIdentity: 'package',
          manifestPath: 'Package.swift',
          manifest:
              'let url = dynamicUrl\n.binaryTarget(name: "Target", url: url, checksum: checksum)',
        ),
        isEmpty,
      );
    });
  });

  group('Windows binary artifacts', () {
    const firstChecksum =
        '1111111111111111111111111111111111111111111111111111111111111111';
    const secondChecksum =
        '2222222222222222222222222222222222222222222222222222222222222222';

    String manifest() =>
        'let targets: [Target] = [\n'
        '  .binaryTarget(name: "First", url: "https://example.invalid/first.zip", checksum: "$firstChecksum"),\n'
        '  .binaryTarget(name: "Second", url: "https://example.invalid/second.zip", checksum: "$secondChecksum"),\n'
        ']\n';

    Future<SwiftPmPreparedBinaryArtifact> preparedArtifact(
      String packageRoot,
      SwiftPmRemoteBinaryTarget target,
    ) async {
      final artifact = Directory(
        p.join(
          packageRoot,
          'prepared',
          target.name,
          '${target.name}.xcframework',
        ),
      )..createSync(recursive: true);
      return SwiftPmPreparedBinaryArtifact(
        target: target,
        entry: SwiftPmBinaryArtifactEntry(
          archiveChecksum: target.checksum,
          targetName: target.name,
          artifactPath: artifact.path,
        ),
      );
    }

    group('stageExtractedBinaryArtifacts', () {
      // A SwiftPM resolve that deleted its archive after extracting it, and
      // may have extracted only part of the tree (I/O error 514 on the
      // Windows runner left a framework without Headers).
      ({String scratch, File manifest}) extractedLayout(String name) {
        final scratch = p.join(tmp.path, name, 'scratch');
        final manifestFile =
            File(p.join(scratch, 'checkouts', 'pkg', 'Package.swift'))
              ..createSync(recursive: true)
              ..writeAsStringSync(manifest().split('\n')[1]);
        final framework = Directory(
          p.join(
            scratch,
            'artifacts',
            'pkg',
            'First',
            'First.xcframework',
            'ios-arm64',
            'First.framework',
          ),
        )..createSync(recursive: true);
        File(p.join(framework.path, 'First')).writeAsStringSync('binary');
        File(
          p.join(
            scratch,
            'artifacts',
            'pkg',
            'First',
            'First.xcframework',
            'Info.plist',
          ),
        ).writeAsStringSync('<plist/>');
        return (scratch: scratch, manifest: manifestFile);
      }

      test(
        'rebuilds from the verified archive instead of a partial extracted tree',
        () async {
          final layout = extractedLayout('partial');
          final store = p.join(tmp.path, 'partial', 'store');
          final prepared = <String>[];
          String? copiedFrom;

          final changed = await _windowsRuntime.extractedArtifacts
              .stageExtractedBinaryArtifacts(
                scratchPath: layout.scratch,
                binaryArtifactStore: store,
                binaryArtifactFallback: p.join(tmp.path, 'partial', 'fb'),
                attemptState: SwiftPmBinaryAttemptState(),

                prepare: (target) {
                  prepared.add(target.name);
                  return preparedArtifact(p.join(tmp.path, 'partial'), target);
                },
                materialize: ({required source, required destination}) async {
                  copiedFrom = source;
                  await Directory(destination).create(recursive: true);
                  return SwiftPmBinaryArtifactPublication.published();
                },
              );

          expect(changed, isTrue);
          expect(prepared, ['First']);
          expect(
            copiedFrom,
            p.join(
              tmp.path,
              'partial',
              'prepared',
              'First',
              'First.xcframework',
            ),
          );
          // The unverified extracted tree must never enter the store.
          expect(Directory(p.join(store, 'targets')).existsSync(), isFalse);
          expect(
            layout.manifest.readAsStringSync(),
            contains('.binaryTarget(name: "First", path: '),
          );
        },
      );

      test(
        'falls back to the extracted tree when the archive is unavailable',
        () async {
          final layout = extractedLayout('offline');
          final store = p.join(tmp.path, 'offline', 'store');

          final changed = await _windowsRuntime.extractedArtifacts
              .stageExtractedBinaryArtifacts(
                scratchPath: layout.scratch,
                binaryArtifactStore: store,
                binaryArtifactFallback: p.join(tmp.path, 'offline', 'fb'),
                attemptState: SwiftPmBinaryAttemptState(),

                prepare: (target) =>
                    throw FlutterBuildError('Failed to download'),
                materialize: ({required source, required destination}) async {
                  await Directory(destination).create(recursive: true);
                  return SwiftPmBinaryArtifactPublication.published();
                },
              );

          expect(changed, isTrue);
          expect(Directory(p.join(store, 'targets')).existsSync(), isFalse);
          final metadata = File(
            p.join(
              tmp.path,
              'offline',
              'fb',
              'extracted-artifacts',
              firstChecksum,
              'First',
              '.xcross-offline.json',
            ),
          );
          expect(
            metadata.readAsStringSync(),
            contains('unverified-extracted-tree'),
          );
        },
      );

      test(
        testOn: '!windows',

        'manifest failure cannot admit offline trees into later verified preparation',
        () async {
          final layout = extractedLayout('offline-manifest-failure');
          final root = p.join(tmp.path, 'offline-manifest-failure');
          final generator = SwiftPmBinaryFixtureGenerator(
            fileSystem: _windowsRuntime.runner.host.fileSystem,
            paths: _windowsRuntime.runner.host.paths.context,
          );
          final fixture = generator.generateXcframework(
            library: const SwiftPmBinaryFixtureLibrary(identifier: 'ios-arm64'),
            root: p.join(root, 'verified-fixture'),
            name: 'First',
          );
          final archive = generator.archiveXcframework(
            framework: fixture,
            output: p.join(root, 'verified-fixture.zip'),
          );
          final bytes = archive.readAsBytesSync();
          final checksum = sha256.convert(bytes).toString();
          final original = layout.manifest.readAsStringSync().replaceFirst(
            firstChecksum,
            checksum,
          );
          layout.manifest.writeAsStringSync(original);
          final storeRoot = p.join(root, 'store');
          final fallback = p.join(root, 'fallback');
          final failure = StateError('original manifest write failed');
          await expectLater(
            _windowsRuntime.extractedArtifacts.stageExtractedBinaryArtifacts(
              scratchPath: layout.scratch,
              binaryArtifactStore: storeRoot,
              binaryArtifactFallback: fallback,
              attemptState: SwiftPmBinaryAttemptState(),
              prepare: (_) => Future.error(
                FlutterBuildError('offline archive unavailable'),
              ),
              materialize: ({required source, required destination}) async {
                await Directory(destination).create(recursive: true);
                return SwiftPmBinaryArtifactPublication.published();
              },
              removeDestination: (destination) =>
                  Directory(destination).delete(recursive: true),
              writeManifest: (_, _) => Future.error(failure),
            ),
            throwsA(same(failure)),
          );
          expect(layout.manifest.readAsStringSync(), original);
          expect(
            Directory(
              p.join(
                layout.manifest.parent.path,
                '.xa',
                checksum.substring(0, 16),
                'First.xcframework',
              ),
            ).existsSync(),
            isFalse,
          );
          final offlineRoot = p.join(
            fallback,
            'extracted-artifacts',
            checksum,
            'First',
          );
          expect(
            File(
              p.join(offlineRoot, '.xcross-offline.json'),
            ).readAsStringSync(),
            contains('unverified-extracted-tree'),
          );
          expect(
            File(p.join(offlineRoot, 'metadata.json')).existsSync(),
            isFalse,
          );
          expect(File(p.join(offlineRoot, '.complete')).existsSync(), isFalse);
          final store = SwiftPmBinaryArtifactStore(
            storeRoot,
            host: _windowsRuntime.host,
            fileSystem: _windowsRuntime.artifactFileSystem,
            publicationCoordinator: _windowsRuntime.publicationCoordinator,
          );
          expect(await store.findCompleteTarget(checksum, 'First'), isNull);
          final transport = FixtureSwiftPmArchiveTransport(bytes);
          final preparer = SwiftPmBinaryArtifactPreparer(
            store: store,
            policy: _windowsRuntime.targetPolicy,
            copyPolicy: _windowsRuntime.copyPolicy,
            transport: transport,
          );
          final target = SwiftPmBinaryTargetManifest.discover(original).single;
          final prepared = await preparer.prepare(target);
          expect(transport.calls, 1);
          expect(p.isWithin(storeRoot, prepared.entry.artifactPath), isTrue);
          expect(p.isWithin(fallback, prepared.entry.artifactPath), isFalse);
          expect(
            (await store.findCompleteTarget(checksum, 'First'))?.artifactPath,
            prepared.entry.artifactPath,
          );
          final cached = await preparer.prepare(target);
          expect(cached.entry.artifactPath, prepared.entry.artifactPath);
          expect(transport.calls, 1);
        },
      );

      test('propagates security failures from archive preparation', () async {
        final layout = extractedLayout('tampered');

        await expectLater(
          _windowsRuntime.extractedArtifacts.stageExtractedBinaryArtifacts(
            scratchPath: layout.scratch,
            binaryArtifactStore: p.join(tmp.path, 'tampered', 'store'),
            binaryArtifactFallback: p.join(tmp.path, 'tampered', 'fb'),
            attemptState: SwiftPmBinaryAttemptState(),

            prepare: (target) => throw FlutterBuildError(
              'checksum mismatch',
              isSecurityFailure: true,
            ),
          ),
          throwsA(
            isA<FlutterBuildError>().having(
              (error) => error.isSecurityFailure,
              'isSecurityFailure',
              isTrue,
            ),
          ),
        );
      });
    });

    test('rewrites successful target and preserves unsupported call', () async {
      final packageRoot = p.join(tmp.path, 'mixed');
      final manifestFile = File(p.join(packageRoot, 'Package.swift'))
        ..createSync(recursive: true)
        ..writeAsStringSync(manifest());
      final originalSecond = manifest().split('\n')[2];

      await _windowsRuntime.binaryPreparation.prepareSupportedBinaryArtifacts(
        packageRoot: packageRoot,
        binaryArtifactStore: p.join(tmp.path, 'store'),
        binaryArtifactFallback: p.join(tmp.path, 'fallback'),
        packageLocalArtifactJunctionCapability: true,

        prepare: (target) {
          if (target.name == 'Second') {
            throw FlutterBuildError('unsupported archive slice');
          }
          return preparedArtifact(packageRoot, target);
        },
        createAlias: ({required alias, required target}) async {
          Directory(alias).createSync(recursive: true);
        },
      );

      final rewritten = manifestFile.readAsStringSync();
      expect(rewritten, contains('.binaryTarget(name: "First", path: '));
      expect(rewritten.split('\n')[2], originalSecond);
    });

    test(
      'materializes stable fallback once across clean staging and recovery',
      () async {
        final fallback = p.join(tmp.path, 'fallback');
        final store = p.join(tmp.path, 'store');
        var materializations = 0;

        Future<SwiftPmBinaryArtifactPublication> materialize({
          required String source,
          required String destination,
        }) async {
          if (Directory(destination).existsSync()) {
            return SwiftPmBinaryArtifactPublication.reused;
          }
          materializations++;
          await Directory(destination).create(recursive: true);
          return SwiftPmBinaryArtifactPublication.published();
        }

        for (final run in ['first-run', 'second-run']) {
          final packageRoot = p.join(tmp.path, run);
          final manifestFile = File(p.join(packageRoot, 'Package.swift'))
            ..createSync(recursive: true)
            ..writeAsStringSync(manifest().split('\n')[1]);
          await _windowsRuntime.binaryPreparation
              .prepareSupportedBinaryArtifacts(
                packageRoot: packageRoot,
                binaryArtifactStore: store,
                binaryArtifactFallback: fallback,
                packageLocalArtifactJunctionCapability: false,

                prepare: (target) => preparedArtifact(tmp.path, target),
                materialize: materialize,
              );

          final stable = p.join(
            packageRoot,
            '.xa',
            firstChecksum.substring(0, 16),
            'First.xcframework',
          );
          expect(
            manifestFile.readAsStringSync(),
            contains(
              p
                  .join(
                    '.xa',
                    firstChecksum.substring(0, 16),
                    'First.xcframework',
                  )
                  .replaceAll(r'\', r'\\'),
            ),
          );

          expect(Directory(stable).existsSync(), isTrue);
        }

        final provenance = binaryProvenance(
          'package',
          'First',
          firstChecksum,
          'Package.swift',
        );
        final stable = p.join(
          fallback,
          firstChecksum,
          'First',
          'First.xcframework',
        );
        final recovery = await _windowsRuntime.binaryRecovery
            .recoverFinalBinaryArtifact(
              provenance: provenance,
              preparedArtifactPath: p.join(
                tmp.path,
                'prepared',
                'First',
                'First.xcframework',
              ),
              binaryArtifactStore: store,
              destination: p.join(
                tmp.path,
                'pruned',
                'xcross-artifacts',
                'First',
              ),
              materializedDestination: stable,
              attemptState: SwiftPmBinaryAttemptState(),
              packageLocalArtifactJunctionCapability: false,
              materialize: materialize,
            );

        expect(recovery, SwiftPmBinaryArtifactPublication.published());
        expect(materializations, 3);
      },
    );

    test(
      'falls back to stable materialization when alias creation fails',
      () async {
        final packageRoot = p.join(tmp.path, 'alias-failure');
        final manifestFile = File(p.join(packageRoot, 'Package.swift'))
          ..createSync(recursive: true)
          ..writeAsStringSync(manifest().split('\n')[1]);
        String? copiedTo;

        await _windowsRuntime.binaryPreparation.prepareSupportedBinaryArtifacts(
          packageRoot: packageRoot,
          binaryArtifactStore: p.join(tmp.path, 'store'),
          binaryArtifactFallback: p.join(tmp.path, 'fallback'),
          packageLocalArtifactJunctionCapability: true,

          prepare: (target) => preparedArtifact(tmp.path, target),
          createAlias: ({required alias, required target}) async =>
              throw FileSystemException('junction unavailable', alias),
          materialize: ({required source, required destination}) async {
            copiedTo = destination;
            await Directory(destination).create(recursive: true);
            return SwiftPmBinaryArtifactPublication.published();
          },
        );

        expect(
          p.windows.normalize(copiedTo!),
          endsWith(
            p.windows.normalize(
              p.join(
                packageRoot,
                '.xa',
                firstChecksum.substring(0, 16),
                'First.xcframework',
              ),
            ),
          ),
        );

        expect(
          manifestFile.readAsStringSync(),
          contains(
            p
                .join(
                  '.xa',
                  firstChecksum.substring(0, 16),
                  'First.xcframework',
                )
                .replaceAll(r'\', r'\\'),
          ),
        );
      },
    );

    test('leaves a download failure call byte-identical', () async {
      final packageRoot = p.join(tmp.path, 'download');
      final original = manifest().split('\n')[1];
      final manifestFile = File(p.join(packageRoot, 'Package.swift'))
        ..createSync(recursive: true)
        ..writeAsStringSync('$original\n');
      var writes = 0;

      await _windowsRuntime.binaryPreparation.prepareSupportedBinaryArtifacts(
        packageRoot: packageRoot,
        binaryArtifactStore: p.join(tmp.path, 'store'),
        binaryArtifactFallback: p.join(tmp.path, 'fallback'),
        packageLocalArtifactJunctionCapability: true,

        prepare: (_) => throw FlutterBuildError('download failed'),
        writeManifest: (_, _) async => writes++,
      );

      expect(manifestFile.readAsStringSync(), '$original\n');
      expect(writes, 0);
    });

    test(
      'checksum failure rolls back aliases without manifest rewrite',
      () async {
        final packageRoot = p.join(tmp.path, 'security');
        final original = manifest();
        final manifestFile = File(p.join(packageRoot, 'Package.swift'))
          ..createSync(recursive: true)
          ..writeAsStringSync(original);
        final aliases = <String>[];
        var writes = 0;

        await expectLater(
          _windowsRuntime.binaryPreparation.prepareSupportedBinaryArtifacts(
            packageRoot: packageRoot,
            binaryArtifactStore: p.join(tmp.path, 'store'),
            binaryArtifactFallback: p.join(tmp.path, 'fallback'),
            packageLocalArtifactJunctionCapability: true,

            prepare: (target) {
              if (target.name == 'Second') {
                throw FlutterBuildError(
                  'checksum mismatch',
                  isSecurityFailure: true,
                );
              }
              return preparedArtifact(packageRoot, target);
            },
            createAlias: ({required alias, required target}) async {
              Directory(alias).createSync(recursive: true);
              aliases.add(alias);
            },
            removeAlias: (alias) async {
              aliases.remove(alias);
              await Directory(alias).delete(recursive: true);
            },
            writeManifest: (_, _) async => writes++,
          ),
          throwsA(
            isA<FlutterBuildError>().having(
              (error) => error.isSecurityFailure,
              'isSecurityFailure',
              isTrue,
            ),
          ),
        );

        expect(aliases, isEmpty);
        expect(manifestFile.readAsStringSync(), original);
        expect(writes, 0);
      },
    );
  });

  group('Windows checkout symlinks', () {
    test(
      testOn: '!windows',

      'materializes tracked file symlinks without duplicate files',
      () async {
        final repo = p.join(tmp.path, 'scratch', 'checkouts', 'dependency');
        Directory(repo).createSync(recursive: true);

        ProcessResult git(List<String> arguments) {
          final result = Process.runSync('git', ['-C', repo, ...arguments]);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}${result.stderr}',
          );
          return result;
        }

        git(['init']);
        final target = File(p.join(repo, 'target.txt'))
          ..writeAsStringSync('materialized');
        final placeholder = File(p.join(repo, 'link.txt'))
          ..writeAsStringSync('target.txt');
        git(['add', 'target.txt', 'link.txt']);
        final hash = (git(['hash-object', '-w', 'link.txt']).stdout as String)
            .trim();
        git(['update-index', '--cacheinfo', '120000', hash, 'link.txt']);
        if (Platform.isWindows) {
          final attrib = Process.runSync('attrib', ['+R', placeholder.path]);
          expect(
            attrib.exitCode,
            0,
            reason: '${attrib.stdout}${attrib.stderr}',
          );
        }

        expect(
          await _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
            p.join(tmp.path, 'scratch'),
          ),
          isTrue,
        );
        expect(
          await _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
            p.join(tmp.path, 'scratch'),
          ),
          isFalse,
        );

        expect(placeholder.readAsStringSync(), 'materialized');
        final updatedPlaceholder = File(p.join(repo, 'updated-link.txt'))
          ..writeAsStringSync('target.txt');
        git(['add', 'updated-link.txt']);
        final updatedHash =
            (git(['hash-object', '-w', 'updated-link.txt']).stdout as String)
                .trim();
        git([
          'update-index',
          '--cacheinfo',
          '120000',
          updatedHash,
          'updated-link.txt',
        ]);
        expect(
          await _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
            p.join(tmp.path, 'scratch'),
          ),
          isTrue,
        );
        expect(updatedPlaceholder.readAsStringSync(), 'materialized');
        if (Platform.isWindows) {
          target.writeAsStringSync('updated');
          expect(placeholder.readAsStringSync(), 'updated');
        }
      },
    );

    test(
      testOn: '!windows',
      'forwards header placeholders to one Clang file identity',
      () async {
        final repo = p.join(tmp.path, 'headers', 'checkouts', 'dependency');
        Directory(p.join(repo, 'Sources')).createSync(recursive: true);
        Directory(p.join(repo, 'include')).createSync(recursive: true);

        ProcessResult git(List<String> arguments) {
          final result = Process.runSync('git', ['-C', repo, ...arguments]);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}${result.stderr}',
          );
          return result;
        }

        git(['init']);
        // A header with no include guard, published under two paths.
        File(
          p.join(repo, 'Sources', 'Types.h'),
        ).writeAsStringSync('typedef enum { kOne } Value;\n');
        final placeholder = File(p.join(repo, 'include', 'Types.h'))
          ..writeAsStringSync('../Sources/Types.h');
        git(['add', 'Sources/Types.h', 'include/Types.h']);
        final hash =
            (git(['hash-object', '-w', 'include/Types.h']).stdout as String)
                .trim();
        git(['update-index', '--cacheinfo', '120000', hash, 'include/Types.h']);

        expect(
          await _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
            p.join(tmp.path, 'headers'),
            symlinks: false,
          ),
          isTrue,
        );

        final materialized = placeholder.readAsStringSync();
        if (Platform.isWindows) {
          // Forwarding leaves one file to parse, so including both paths
          // cannot redefine the declarations.
          expect(materialized, '#include "../Sources/Types.h"\n');
          expect(materialized, isNot(contains('typedef enum')));
        } else {
          expect(materialized, contains('typedef enum'));
        }
      },
    );

    test(
      testOn: '!windows',
      'restores real symlinks and verifies them without git',
      () async {
        if (!await _swiftPmRuntime.symlinks.probe()) {
          markTestSkipped('host cannot create symlinks');
          return;
        }
        final scratch = p.join(tmp.path, 'symlinks');
        final repo = p.join(scratch, 'checkouts', 'dependency');
        Directory(
          p.join(repo, 'Sources', 'nested'),
        ).createSync(recursive: true);
        Directory(p.join(repo, 'include')).createSync(recursive: true);

        ProcessResult git(List<String> arguments) {
          final result = Process.runSync('git', [
            '-c',
            'core.symlinks=false',
            '-C',
            repo,
            ...arguments,
          ]);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}${result.stderr}',
          );
          return result;
        }

        git(['init']);
        git(['config', 'user.email', 'xcross@example.invalid']);
        git(['config', 'user.name', 'xcross']);
        File(
          p.join(repo, 'Sources', 'Types.h'),
        ).writeAsStringSync('typedef int T;\n');
        File(p.join(repo, 'Package.swift')).writeAsStringSync(
          'let package = Package(targets: [.target(name: "Dependency", '
          'path: "Sources")])',
        );
        File(p.join(repo, 'Sources', 'nested', 'a.txt')).writeAsStringSync('a');
        final fileLink = File(p.join(repo, 'include', 'Types.h'))
          ..writeAsStringSync('../Sources/Types.h');
        final dirLink = File(p.join(repo, 'include', 'nested'))
          ..writeAsStringSync('../Sources/nested');
        final danglingLink = File(p.join(repo, 'include', 'optional-example'))
          ..writeAsStringSync('../Sources/not-present');
        git(['add', 'Package.swift', 'Sources', 'include']);
        for (final link in [
          'include/Types.h',
          'include/nested',
          'include/optional-example',
        ]) {
          final hash = (git(['hash-object', '-w', link]).stdout as String)
              .trim();
          git(['update-index', '--cacheinfo', '120000', hash, link]);
        }
        git(['commit', '-q', '-m', 'links']);

        expect(
          await _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
            scratch,
            symlinks: true,
          ),
          isTrue,
        );
        expect(FileSystemEntity.isLinkSync(fileLink.path), isTrue);

        expect(FileSystemEntity.isLinkSync(dirLink.path), isTrue);
        expect(FileSystemEntity.isLinkSync(danglingLink.path), isTrue);
        expect(
          Link(danglingLink.path).targetSync(),
          Platform.isWindows
              ? r'..\Sources\not-present'
              : '../Sources/not-present',
        );
        expect(fileLink.readAsStringSync(), 'typedef int T;\n');
        expect(File(p.join(dirLink.path, 'a.txt')).readAsStringSync(), 'a');

        final stamp = Directory(
          p.join(scratch, '.xcross-symlinks'),
        ).listSync().whereType<File>().single;
        final oldStamp =
            jsonDecode(stamp.readAsStringSync()) as Map<String, dynamic>;
        oldStamp['version'] = 2;
        stamp.writeAsStringSync(jsonEncode(oldStamp));
        expect(
          await _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
            scratch,
            symlinks: true,
          ),
          isFalse,
        );
        expect((jsonDecode(stamp.readAsStringSync()) as Map)['version'], 3);

        // Warm build: the stamp is keyed on HEAD and every link still holds,
        // so no git process is needed to conclude nothing changed.
        expect(
          await _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
            scratch,
            symlinks: true,
            git: p.join(tmp.path, 'git-must-not-run'),
          ),
          isFalse,
        );

        // A dangling Git link can acquire a directory target after checkout.
        // On Windows, its original file-typed reparse point must be replaced.
        // A POSIX symlink already follows its new target, so only Windows has
        // something to replace.
        Directory(p.join(repo, 'Sources', 'not-present')).createSync();
        expect(
          await _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
            scratch,
            symlinks: true,
          ),
          Platform.isWindows,
        );
        expect(Directory(danglingLink.path).existsSync(), isTrue);

        if (Platform.isWindows) {
          // `mklink` without /D deliberately creates a file-typed link to a
          // directory. A matching target string alone is not enough to reuse it.
          Link(dirLink.path).deleteSync();
          final wrongKind = Process.runSync('cmd', [
            '/c',
            'mklink',
            dirLink.path,
            r'..\Sources\nested',
          ]);
          expect(
            wrongKind.exitCode,
            0,
            reason: '${wrongKind.stdout}${wrongKind.stderr}',
          );
          expect(Directory(dirLink.path).existsSync(), isFalse);
          expect(
            await _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
              scratch,
              symlinks: true,
            ),
            isTrue,
          );
          expect(Directory(dirLink.path).existsSync(), isTrue);
        }

        // A placeholder brought back by a `reset --hard` under
        // `core.symlinks=false` is detected and restored.
        Link(fileLink.path).deleteSync();
        fileLink.writeAsStringSync('../Sources/Types.h');
        expect(
          await _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
            scratch,
            symlinks: true,
          ),
          isTrue,
        );
        expect(FileSystemEntity.isLinkSync(fileLink.path), isTrue);
        final requiredLink = File(p.join(repo, 'Sources', 'required.h'))
          ..writeAsStringSync('missing.h');
        git(['add', 'Sources/required.h']);
        final requiredHash =
            (git(['hash-object', '-w', requiredLink.path]).stdout as String)
                .trim();
        git([
          'update-index',
          '--cacheinfo',
          '120000',
          requiredHash,
          'Sources/required.h',
        ]);
        git(['commit', '-q', '-m', 'required source link']);
        await expectLater(
          _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
            scratch,
            symlinks: true,
          ),
          throwsA(isA<FlutterBuildError>()),
        );
      },
    );

    test(
      testOn: '!windows',
      'allows a missing symlink in a test-only target',
      () async {
        if (!await _swiftPmRuntime.symlinks.probe()) {
          markTestSkipped('host cannot create symlinks');
          return;
        }
        final scratch = p.join(tmp.path, 'test-target-links');
        final repo = p.join(scratch, 'checkouts', 'dependency');
        Directory(
          p.join(repo, 'Tests', 'PluginTests'),
        ).createSync(recursive: true);
        ProcessResult git(List<String> arguments) {
          final result = Process.runSync('git', [
            '-c',
            'core.symlinks=false',
            '-C',
            repo,
            ...arguments,
          ]);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}${result.stderr}',
          );
          return result;
        }

        git(['init']);
        File(p.join(repo, 'Package.swift')).writeAsStringSync(
          'let package = Package(targets: [.testTarget(name: "PluginTests")])',
        );
        final link = File(p.join(repo, 'Tests', 'PluginTests', 'fixture.txt'))
          ..writeAsStringSync('missing.txt');
        git(['add', 'Package.swift', 'Tests']);
        final hash = (git(['hash-object', '-w', link.path]).stdout as String)
            .trim();
        git([
          'update-index',
          '--cacheinfo',
          '120000',
          hash,
          'Tests/PluginTests/fixture.txt',
        ]);
        expect(
          await _swiftPmRuntime.checkout.materializeCheckoutSymlinks(
            scratch,
            symlinks: true,
          ),
          isTrue,
        );
        expect(FileSystemEntity.isLinkSync(link.path), isTrue);
      },
    );
  });

  group('removeMissingResources', () {
    test('drops missing resources and preserves existing resources', () {
      final package = Directory(p.join(tmp.path, 'resources'))
        ..createSync(recursive: true);
      File(p.join(package.path, 'PrivacyInfo.xcprivacy'))
        ..createSync()
        ..writeAsStringSync('{}');
      const manifest = '''
resources: [
    .process("PrivacyInfo.xcprivacy"),
    .copy("Resources/Missing.bundle"),
]
''';

      final normalized = _swiftPmRuntime.sourceNormalizer
          .removeMissingResources(manifest, package.path);
      expect(normalized, contains('.process("PrivacyInfo.xcprivacy")'));
      expect(normalized, isNot(contains('Missing.bundle')));
    });

    test('resolves resources relative to their target path', () {
      final package = Directory(p.join(tmp.path, 'target-resources'))
        ..createSync(recursive: true);
      File(
          p.join(
            package.path,
            'Sources',
            'flutter_inappwebview_ios',
            'Resources',
            'WebView.storyboard',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('<storyboard/>');
      const manifest = '''
let package = Package(targets: [
    .target(
        name: "flutter_inappwebview_ios",
        path: "Sources/flutter_inappwebview_ios",
        resources: [
            .process("Resources/WebView.storyboard"),
            .process("Resources/Missing.xcprivacy"),
        ]
    )
])
''';

      final normalized = _swiftPmRuntime.sourceNormalizer
          .removeMissingResources(manifest, package.path);
      expect(normalized, contains('.process("Resources/WebView.storyboard")'));
      expect(normalized, isNot(contains('Missing.xcprivacy')));
    });

    test('uses the conventional Sources target directory', () {
      final package = Directory(p.join(tmp.path, 'default-target-resources'))
        ..createSync(recursive: true);
      File(p.join(package.path, 'Sources', 'Plugin', 'Resources', 'Data.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      const manifest = '''
.target(name: "Plugin", resources: [.copy("Resources/Data.json")])
''';

      expect(
        _swiftPmRuntime.sourceNormalizer.removeMissingResources(
          manifest,
          package.path,
        ),
        manifest,
      );
    });
  });

  group('registrantSource', () {
    void writeBinaryPlist(
      String frameworkPath, {
      bool simulator = false,
      bool binary = false,
    }) {
      final libraries = <String>[
        '''
<dict><key>LibraryIdentifier</key><string>ios-arm64</string>
<key>SupportedPlatform</key><string>ios</string>
<key>SupportedArchitectures</key><array><string>arm64</string></array></dict>
''',
        if (simulator)
          '''
<dict><key>LibraryIdentifier</key><string>ios-arm64-simulator</string>
<key>SupportedPlatform</key><string>ios</string>
<key>SupportedPlatformVariant</key><string>simulator</string>
<key>SupportedArchitectures</key><array><string>arm64</string></array></dict>
''',
      ];
      final xml =
          '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
          '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
          '<plist version="1.0"><dict><key>AvailableLibraries</key>\n'
          '<array>${libraries.join()}</array></dict></plist>';
      final file = File(p.join(frameworkPath, 'Info.plist'))
        ..createSync(recursive: true);
      if (binary) {
        final data = PropertyListSerialization.dataWithPropertyList(
          PropertyListSerialization.propertyListWithString(xml),
        );
        file.writeAsBytesSync(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      } else {
        file.writeAsStringSync(xml);
      }
    }

    test('imports and registers only the plugin with a pluginClass', () {
      final pluginA = makePlugin('plugin_a', pluginClass: 'PluginA');
      final pluginB = makePlugin('plugin_b');

      final source = _swiftPmRuntime.manifest.registrantSource([
        pluginA,
        pluginB,
      ]);

      expect(source, contains('import plugin_a'));
      expect(source, isNot(contains('import plugin_b')));
      expect(
        source,
        contains('if let registrar = registry.registrar(forPlugin: "PluginA")'),
      );
      expect(source, contains('PluginA.register(with: registrar)'));
      // Exactly one registration block: only plugin_a has a pluginClass.
      expect('if let registrar'.allMatches(source).length, 1);
      expect(source, contains('@_cdecl("XcrossRegisterGeneratedPlugins")'));
      expect(source, isNot(contains('[xcross] registering plugin')));
    });

    test('guards an explicitly newer Swift plugin class at runtime', () {
      final plugin = makePlugin('new_plugin', pluginClass: 'NewPlugin');
      final source = File(
        p.join(
          plugin.swiftPackageDir,
          'Sources',
          'new_plugin',
          'NewPlugin.swift',
        ),
      );
      source.createSync(recursive: true);
      source.writeAsStringSync('''
import Flutter
@available(iOS 17.0, *)
public class NewPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
''');

      expect(
        plugin.pluginClassIosAvailabilityIn(
          policy: _swiftPmRuntime.targetPolicy,
        ),
        '17.0',
      );
      final registrant = _swiftPmRuntime.manifest.registrantSource([plugin]);
      expect(registrant, contains('if #available(iOS 17.0, *) {'));
      expect(registrant, contains('NewPlugin.register(with: registrar)'));
      expect(registrant, isNot(contains('NSClassFromString')));
      final verbose = _swiftPmRuntime.manifest.registrantSource([
        plugin,
      ], verbose: true);
      expect(verbose, contains('requires iOS 17.0'));
    });

    test('guards a binary-only plugin using its Swift interface', () {
      final plugin = makePlugin('new_plugin', pluginClass: 'NewPlugin');
      final frameworkPath = p.join(
        plugin.swiftPackageDir,
        'NewPlugin.xcframework',
      );
      writeBinaryPlist(frameworkPath, simulator: true);
      final interface = File(
        p.join(
          frameworkPath,
          'ios-arm64',
          'NewPlugin.framework',
          'Modules',
          'NewPlugin.swiftmodule',
          'arm64-apple-ios.swiftinterface',
        ),
      )..createSync(recursive: true);
      interface.writeAsStringSync('''
@available(iOS 17.0, *)
public class NewPlugin: NSObject, FlutterPlugin {}
''');
      final simulatorInterface = File(
        interface.path.replaceFirst('ios-arm64', 'ios-arm64-simulator'),
      )..createSync(recursive: true);
      simulatorInterface.writeAsStringSync('''
@available(iOS 18.0, *)
public class NewPlugin: NSObject, FlutterPlugin {}
''');

      expect(
        plugin.pluginClassIosAvailabilityIn(
          policy: _swiftPmRuntime.targetPolicy,
        ),
        '17.0',
      );
      expect(
        _swiftPmRuntime.manifest.registrantSource([plugin]),
        contains('if #available(iOS 17.0, *)'),
      );
    });

    test('finds downloaded binary interfaces in the staged package', () {
      final plugin = makePlugin('new_plugin', pluginClass: 'NewPlugin');
      final staged = p.join(tmp.path, 'staged-new-plugin');
      final frameworkPath = p.join(staged, 'NewPlugin.xcframework');
      writeBinaryPlist(frameworkPath, binary: true);
      final interface = File(
        p.join(
          frameworkPath,
          'ios-arm64',
          'NewPlugin.framework',
          'Modules',
          'NewPlugin.swiftmodule',
          'arm64-apple-ios.swiftinterface',
        ),
      )..createSync(recursive: true);
      interface.writeAsStringSync('''
@available(iOS 17.0, *) public class NewPlugin: NSObject, FlutterPlugin {}
''');

      expect(
        plugin.pluginClassIosAvailabilityIn(
          policy: _swiftPmRuntime.targetPolicy,
        ),
        isNull,
      );
      expect(
        _swiftPmRuntime.manifest.registrantSource(
          [plugin],
          stagedPackageDirs: {'new_plugin': staged},
        ),
        contains('if #available(iOS 17.0, *)'),
      );
    });

    test('follows a staged XCFramework artifact alias', () {
      final plugin = makePlugin('new_plugin', pluginClass: 'NewPlugin');
      final frameworkPath = p.join(tmp.path, 'store', 'NewPlugin.xcframework');
      writeBinaryPlist(frameworkPath);
      final interface = File(
        p.join(
          frameworkPath,
          'ios-arm64',
          'NewPlugin.framework',
          'Modules',
          'NewPlugin.swiftmodule',
          'arm64-apple-ios.swiftinterface',
        ),
      )..createSync(recursive: true);
      interface.writeAsStringSync('''
@available(iOS 17.0, *)
public class NewPlugin: NSObject, FlutterPlugin {}
''');
      final staged = p.join(tmp.path, 'staged-linked-plugin');
      final alias = p.join(staged, '.xa', 'checksum', 'NewPlugin.xcframework');
      Directory(p.dirname(alias)).createSync(recursive: true);
      if (Platform.isWindows) {
        final result = Process.runSync('cmd.exe', [
          '/c',
          'mklink',
          '/J',
          alias,
          frameworkPath,
        ]);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      } else {
        Link(alias).createSync(frameworkPath);
      }

      expect(
        _swiftPmRuntime.manifest.registrantSource(
          [plugin],
          stagedPackageDirs: {'new_plugin': staged},
        ),
        contains('if #available(iOS 17.0, *)'),
      );
    });

    test('does not inherit availability from an intervening declaration', () {
      final plugin = makePlugin('new_plugin', pluginClass: 'NewPlugin');
      final source = File(
        p.join(plugin.swiftPackageDir, 'Sources', 'NewPlugin.swift'),
      )..createSync(recursive: true);
      source.writeAsStringSync('''
@available(iOS 17.0, *)
public typealias NewAlias = String
public class NewPlugin: NSObject, FlutterPlugin {}
''');

      expect(
        plugin.pluginClassIosAvailabilityIn(
          policy: _swiftPmRuntime.targetPolicy,
        ),
        isNull,
      );
      expect(
        _swiftPmRuntime.manifest.registrantSource([plugin]),
        isNot(contains('if #available(iOS 17.0, *)')),
      );
    });

    test('uses the highest stacked iOS availability requirement', () {
      final plugin = makePlugin('new_plugin', pluginClass: 'NewPlugin');
      final source = File(
        p.join(plugin.swiftPackageDir, 'Sources', 'NewPlugin.swift'),
      )..createSync(recursive: true);
      source.writeAsStringSync('''
@available(iOS 18.0, *)
@available(iOS 17.0, *)
public class NewPlugin: NSObject, FlutterPlugin {}
''');

      expect(
        plugin.pluginClassIosAvailabilityIn(
          policy: _swiftPmRuntime.targetPolicy,
        ),
        '18.0',
      );
      expect(
        _swiftPmRuntime.manifest.registrantSource([plugin]),
        contains('if #available(iOS 18.0, *)'),
      );
    });

    test('recognizes long-form iOS availability and ignores comments', () {
      final plugin = makePlugin('new_plugin', pluginClass: 'NewPlugin');
      final source = File(
        p.join(plugin.swiftPackageDir, 'Sources', 'NewPlugin.swift'),
      )..createSync(recursive: true);
      source.writeAsStringSync('''
/*
@available(iOS 99.0, *)
public class NewPlugin: NSObject, FlutterPlugin {}
*/
// @available(iOS 98.0, *)
@available(iOS, introduced: 17.0)
public class NewPlugin: NSObject, FlutterPlugin {}
''');

      expect(
        plugin.pluginClassIosAvailabilityIn(
          policy: _swiftPmRuntime.targetPolicy,
        ),
        '17.0',
      );
      expect(
        _swiftPmRuntime.manifest.registrantSource([plugin]),
        contains('if #available(iOS 17.0, *)'),
      );
    });

    test('recognizes iOS availability after another Swift platform', () {
      final plugin = makePlugin('new_plugin', pluginClass: 'NewPlugin');
      final source = File(
        p.join(plugin.swiftPackageDir, 'Sources', 'NewPlugin.swift'),
      )..createSync(recursive: true);
      source.writeAsStringSync('''
@available(macOS 10.15, iOS 17.0, *)
public class NewPlugin: NSObject, FlutterPlugin {}
''');

      expect(
        plugin.pluginClassIosAvailabilityIn(
          policy: _swiftPmRuntime.targetPolicy,
        ),
        '17.0',
      );
    });

    test('ignores fake Swift classes inside multiline strings', () {
      final plugin = makePlugin('new_plugin', pluginClass: 'NewPlugin');
      final source = File(
        p.join(plugin.swiftPackageDir, 'Sources', 'NewPlugin.swift'),
      )..createSync(recursive: true);
      source.writeAsStringSync('''
let example = """
@available(iOS 17.0, *)
class NewPlugin
"""
public class NewPlugin: NSObject, FlutterPlugin {}
''');

      expect(
        plugin.pluginClassIosAvailabilityIn(
          policy: _swiftPmRuntime.targetPolicy,
        ),
        isNull,
      );
    });

    test('recognizes Objective-C API_AVAILABLE on a plugin interface', () {
      final plugin = makePlugin('new_plugin', pluginClass: 'NewPlugin');
      final source = File(
        p.join(plugin.swiftPackageDir, 'Sources', 'NewPlugin.h'),
      )..createSync(recursive: true);
      source.writeAsStringSync('''
API_AVAILABLE(macos(10.15), ios(17.0))
@interface NewPlugin : NSObject <FlutterPlugin>
@end
''');

      expect(
        plugin.pluginClassIosAvailabilityIn(
          policy: _swiftPmRuntime.targetPolicy,
        ),
        '17.0',
      );
      expect(
        _swiftPmRuntime.manifest.registrantSource([plugin]),
        contains('if #available(iOS 17.0, *)'),
      );
    });

    test('verbose source tracks each plugin and prints a summary', () {
      final source = _swiftPmRuntime.manifest.registrantSource([
        makePlugin('plugin_a', pluginClass: 'PluginA'),
      ], verbose: true);

      expect(
        source,
        contains('[xcross] registering plugin plugin_a (PluginA)'),
      );
      expect(source, contains('[xcross] registered plugin plugin_a (PluginA)'));
      expect(
        source,
        contains(
          '[xcross] failed plugin plugin_a (PluginA): registrar unavailable',
        ),
      );
      expect(source, contains(r'1 attempted, \(registered) registered'));
      expect(source, contains(r'\(failures.count) failed'));
      expect(source, contains(r'plugin registration failure: \(failure)'));
    });

    test(
      'emits a function with an empty body when no plugin has a pluginClass',
      () {
        final pluginA = makePlugin('plugin_a');

        final source = _swiftPmRuntime.manifest.registrantSource([pluginA]);

        expect(source, isNot(contains('import plugin_a')));
        expect(source, isNot(contains('if let registrar')));
        expect(
          source,
          contains(
            'public func xcrossRegisterGeneratedPlugins(_ registry: '
            'FlutterPluginRegistry) {\n}',
          ),
        );
      },
    );
  });

  group('writeGeneratedPackages', () {
    test(
      'stages normalized plugin manifest without modifying source',
      () async {
        const pluginManifest = '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "plugin_a",
    targets: [
        .target(
            name: "plugin_a",
            linkerSettings: [
                .unsafeFlags(["-Wl,-undefined,dynamic_lookup"])
            ]
        )
    ]
)
''';
        final plugin = makePlugin('plugin_a', packageManifest: pluginManifest);
        final source =
            File(
                p.join(
                  plugin.swiftPackageDir,
                  'Sources',
                  'plugin_a',
                  'source.m',
                ),
              )
              ..createSync(recursive: true)
              ..writeAsStringSync('source');
        final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
        Directory(flutterXcframework).createSync(recursive: true);
        final outputDir = p.join(tmp.path, 'out');

        await _swiftPmRuntime.workspaceStager.writeGeneratedPackages(
          outputDir: outputDir,
          plugins: [plugin],
          flutterXcframework: flutterXcframework,
          copyFlutterXcframework: true,
          deploymentTarget: const IosDeploymentTarget(
            '15.6',
            platform: IPhoneBuildPlatform(),
          ),
        );

        final stagedPluginDir = p.join(outputDir, 'Packages', 'plugin_a');
        expect(Link(stagedPluginDir).existsSync(), isFalse);
        expect(
          File(p.join(stagedPluginDir, 'Package.swift')).readAsStringSync(),
          contains('"-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"'),
        );
        expect(
          File(
            p.join(plugin.swiftPackageDir, 'Package.swift'),
          ).readAsStringSync(),
          pluginManifest,
        );
        expect(
          File(
            p.join(stagedPluginDir, 'Sources', 'plugin_a', 'source.m'),
          ).readAsStringSync(),
          'source',
        );
        expect(source.readAsStringSync(), 'source');
        expect(
          p.normalize(p.join(stagedPluginDir, '..', 'FlutterFramework')),
          p.normalize(p.join(outputDir, 'Packages', 'FlutterFramework')),
        );
      },
    );

    test('stages a real directory copy on the Windows lane', () async {
      const manifest = '''
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "generic_plugin")
''';
      final plugin = makePlugin('generic_plugin', packageManifest: manifest);
      final original =
          File(
              p.join(
                plugin.swiftPackageDir,
                'Sources',
                'GenericPlugin',
                'Feature.swift',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsStringSync('let runtime = true\r\n');
      final originalBytes = original.readAsBytesSync();
      final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
      Directory(flutterXcframework).createSync(recursive: true);
      final outputDir = p.join(tmp.path, 'out');

      await _swiftPmRuntime.workspaceStager.writeGeneratedPackages(
        outputDir: outputDir,
        plugins: [plugin],
        copyPluginPackages: {plugin.name},
        flutterXcframework: flutterXcframework,
        copyFlutterXcframework: true,
        deploymentTarget: const IosDeploymentTarget(
          '15.6',
          platform: IPhoneBuildPlatform(),
        ),
      );
      final staged = File(
        p.join(
          outputDir,
          'Packages',
          'generic_plugin',
          'ios',
          'generic_plugin',
          'Sources',
          'GenericPlugin',
          'Feature.swift',
        ),
      );
      expect(staged.existsSync(), isTrue);
      expect(staged.readAsBytesSync(), originalBytes);
      expect(
        FileSystemEntity.typeSync(
          p.join(
            outputDir,
            'Packages',
            'generic_plugin',
            'ios',
            'generic_plugin',
          ),
          followLinks: false,
        ),
        FileSystemEntityType.directory,
      );
      // The staged copy is independent: it holds the source's bytes at
      // the time of staging, not an alias of the original.
      expect(original.readAsBytesSync(), originalBytes);
    });

    test('stages reachable siblings but not development directories', () async {
      const manifest = '''
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "sibling_plugin")
''';
      final plugin = makePlugin('sibling_plugin', packageManifest: manifest);
      final packageRoot = p.dirname(p.dirname(plugin.swiftPackageDir));
      // Reachable sibling sources, like soloud's `../../src` includes.
      File(p.join(packageRoot, 'src', 'engine.cpp'))
        ..createSync(recursive: true)
        ..writeAsStringSync('// native');
      // Shared Darwin sources are reachable from the iOS package too.
      File(p.join(packageRoot, 'darwin', 'Shared.swift'))
        ..createSync(recursive: true)
        ..writeAsStringSync('let shared = true');
      // Entries no iOS SwiftPM build can reference.
      for (final unreachable in [
        p.join('example', 'main.dart'),
        p.join('test', 'plugin_test.dart'),
        p.join('lib', 'plugin.dart'),
        p.join('android', 'build.gradle'),
        p.join('macos', 'Info.plist'),
        p.join('windows', 'CMakeLists.txt'),
        p.join('linux', 'CMakeLists.txt'),
        p.join('web', 'plugin_web.dart'),
        p.join('pigeons', 'messages.dart'),
        'pubspec.yaml',
        'analysis_options.yaml',
        'README.md',
      ]) {
        File(p.join(packageRoot, unreachable))
          ..createSync(recursive: true)
          ..writeAsStringSync('unreachable');
      }
      final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
      Directory(flutterXcframework).createSync(recursive: true);
      final outputDir = p.join(tmp.path, 'out');

      await _swiftPmRuntime.workspaceStager.writeGeneratedPackages(
        outputDir: outputDir,
        plugins: [plugin],
        copyPluginPackages: {plugin.name},
        flutterXcframework: flutterXcframework,
        copyFlutterXcframework: true,
        deploymentTarget: const IosDeploymentTarget(
          '15.6',
          platform: IPhoneBuildPlatform(),
        ),
      );

      final stagedRoot = p.join(outputDir, 'Packages', 'sibling_plugin');
      expect(
        File(p.join(stagedRoot, 'src', 'engine.cpp')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(stagedRoot, 'darwin', 'Shared.swift')).existsSync(),
        isTrue,
      );
      for (final excluded in [
        'example',
        'test',
        'lib',
        'android',
        'macos',
        'windows',
        'linux',
        'web',
        'pigeons',
        'pubspec.yaml',
        'analysis_options.yaml',
        'README.md',
      ]) {
        expect(
          FileSystemEntity.typeSync(p.join(stagedRoot, excluded)),
          FileSystemEntityType.notFound,
          reason: '$excluded should not be staged',
        );
      }
    });

    test('restaging unchanged sources keeps staged timestamps', () async {
      const manifest = '''
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "stable_plugin")
''';
      final plugin = makePlugin('stable_plugin', packageManifest: manifest);
      File(
          p.join(
            plugin.swiftPackageDir,
            'Sources',
            'StablePlugin',
            'Feature.swift',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('let runtime = true\n');
      final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
      Directory(flutterXcframework).createSync(recursive: true);
      File(
        p.join(flutterXcframework, 'Info.plist'),
      ).writeAsStringSync('<plist/>');
      final outputDir = p.join(tmp.path, 'out');

      Future<void> stage() =>
          _swiftPmRuntime.workspaceStager.writeGeneratedPackages(
            outputDir: outputDir,
            plugins: [plugin],
            copyPluginPackages: {plugin.name},
            flutterXcframework: flutterXcframework,
            copyFlutterXcframework: true,
            deploymentTarget: const IosDeploymentTarget(
              '15.6',
              platform: IPhoneBuildPlatform(),
            ),
          );

      await stage();
      final staged = [
        p.join(
          outputDir,
          'Packages',
          'stable_plugin',
          'ios',
          'stable_plugin',
          'Sources',
          'StablePlugin',
          'Feature.swift',
        ),
        p.join(
          outputDir,
          'Packages',
          'stable_plugin',
          'ios',
          'stable_plugin',
          'Package.swift',
        ),
        p.join(outputDir, 'Plugins', 'Package.swift'),
        p.join(
          outputDir,
          'Packages',
          'FlutterFramework',
          'Flutter.xcframework',
          'Info.plist',
        ),
      ];
      final before = [for (final path in staged) File(path).lastModifiedSync()];

      // SwiftPM rebuilds what changed on disk, so an unchanged plugin must
      // restage without touching a single staged file.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await stage();

      for (var i = 0; i < staged.length; i++) {
        expect(
          File(staged[i]).lastModifiedSync(),
          before[i],
          reason: '${staged[i]} was rewritten without a source change',
        );
      }
    });

    test('preserves packageRoot/ios/package ancestry when copying', () async {
      final plugin = makePlugin(
        'plugin_a',
        packageManifest: '''
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "plugin_a",
    dependencies: [.package(path: "../FlutterFramework")]
)
''',
      );
      File(p.join(plugin.packageRoot, 'src', 'flutter_soloud.cpp'))
        ..createSync(recursive: true)
        ..writeAsStringSync('source');
      File(p.join(plugin.packageRoot, 'ios', 'FlutterFramework', 'stale'))
        ..createSync(recursive: true)
        ..writeAsStringSync('stale');
      final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
      Directory(flutterXcframework).createSync(recursive: true);
      final outputDir = p.join(tmp.path, 'out');

      await _swiftPmRuntime.workspaceStager.writeGeneratedPackages(
        outputDir: outputDir,
        plugins: [plugin],
        copyPluginPackages: {plugin.name},
        flutterXcframework: flutterXcframework,
        copyFlutterXcframework: true,
        deploymentTarget: const IosDeploymentTarget(
          '15.6',
          platform: IPhoneBuildPlatform(),
        ),
      );

      final stagedPackage = p.join(
        outputDir,
        'Packages',
        'plugin_a',
        'ios',
        'plugin_a',
      );
      expect(File(p.join(stagedPackage, 'Package.swift')).existsSync(), isTrue);
      expect(
        File(
          p.normalize(
            p.join(stagedPackage, '..', '..', 'src', 'flutter_soloud.cpp'),
          ),
        ).readAsStringSync(),
        'source',
      );
      expect(
        File(p.join(outputDir, 'Plugins', 'Package.swift')).readAsStringSync(),
        contains(swiftPath(stagedPackage)),
      );
      final relativeFramework = Directory(
        p.normalize(p.join(stagedPackage, '..', 'FlutterFramework')),
      );
      final sharedFramework = Directory(
        p.join(outputDir, 'Packages', 'FlutterFramework'),
      );
      expect(relativeFramework.existsSync(), isTrue);
      expect(
        relativeFramework.resolveSymbolicLinksSync(),
        sharedFramework.resolveSymbolicLinksSync(),
      );
      expect(
        File(p.join(relativeFramework.path, 'stale')).existsSync(),
        isFalse,
      );
    });

    test('stages a sharedDarwinSource plugin from its darwin/ dir', () async {
      final plugin = makePlugin(
        'shared_prefs_foundation',
        sharedDarwinSource: true,
        packageManifest: '''
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "shared_prefs_foundation")
''',
      );
      final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
      Directory(flutterXcframework).createSync(recursive: true);
      final outputDir = p.join(tmp.path, 'out');

      await _swiftPmRuntime.workspaceStager.writeGeneratedPackages(
        outputDir: outputDir,
        plugins: [plugin],
        copyPluginPackages: {plugin.name},
        flutterXcframework: flutterXcframework,
        deploymentTarget: const IosDeploymentTarget(
          '15.6',
          platform: IPhoneBuildPlatform(),
        ),
      );

      // The aggregate manifest has to point at the staged darwin package,
      // otherwise SwiftPM never compiles it and the plugin is missing from
      // the app at runtime.
      final manifest = File(
        p.join(outputDir, 'Plugins', 'Package.swift'),
      ).readAsStringSync();
      expect(manifest, contains('shared_prefs_foundation'));
      expect(
        Directory(
          p.join(outputDir, 'Packages', 'shared_prefs_foundation'),
        ).existsSync(),
        isTrue,
      );
    });

    test(
      'preserves packageRoot/darwin/package ancestry when copying',
      () async {
        final plugin = makePlugin(
          'shared_darwin_plugin',
          sharedDarwinSource: true,
          packageManifest: '''
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "shared_darwin_plugin",
    dependencies: [.package(path: "../FlutterFramework")]
)
''',
        );
        // A sibling the darwin package reaches via ../../src.
        File(p.join(plugin.packageRoot, 'src', 'shared.cpp'))
          ..createSync(recursive: true)
          ..writeAsStringSync('source');
        final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
        Directory(flutterXcframework).createSync(recursive: true);
        final outputDir = p.join(tmp.path, 'out');

        await _swiftPmRuntime.workspaceStager.writeGeneratedPackages(
          outputDir: outputDir,
          plugins: [plugin],
          copyPluginPackages: {plugin.name},
          flutterXcframework: flutterXcframework,
          copyFlutterXcframework: true,
          deploymentTarget: const IosDeploymentTarget(
            '15.6',
            platform: IPhoneBuildPlatform(),
          ),
        );

        // The staged tree keeps the darwin/ shape, so the manifest's relative
        // paths resolve exactly as they do in the pub cache.
        final stagedPackage = p.join(
          outputDir,
          'Packages',
          'shared_darwin_plugin',
          'darwin',
          'shared_darwin_plugin',
        );
        expect(
          File(p.join(stagedPackage, 'Package.swift')).existsSync(),
          isTrue,
        );
        expect(
          File(
            p.normalize(p.join(stagedPackage, '..', '..', 'src', 'shared.cpp')),
          ).readAsStringSync(),
          'source',
        );
        expect(
          File(
            p.join(outputDir, 'Plugins', 'Package.swift'),
          ).readAsStringSync(),
          contains(swiftPath(stagedPackage)),
        );
        // FlutterFramework is aliased next to the package inside darwin/.
        expect(
          Directory(
            p.normalize(p.join(stagedPackage, '..', 'FlutterFramework')),
          ).existsSync(),
          isTrue,
        );
      },
    );

    test(
      'stages plugin packages beside one FlutterFramework package',
      () async {
        const pluginManifest = '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "plugin_a",
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "plugin_a",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
''';
        final pluginA = makePlugin('plugin_a', packageManifest: pluginManifest);
        final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
        Directory(flutterXcframework).createSync(recursive: true);
        final outputDir = p.join(tmp.path, 'out');

        await _swiftPmRuntime.workspaceStager.writeGeneratedPackages(
          outputDir: outputDir,
          plugins: [pluginA],
          flutterXcframework: flutterXcframework,
          copyFlutterXcframework: true,
          deploymentTarget: const IosDeploymentTarget(
            '15.6',
            platform: IPhoneBuildPlatform(),
          ),
        );

        final packagesDir = p.join(outputDir, 'Packages');
        final stagedPluginDir = p.join(packagesDir, 'plugin_a');
        final stagedFrameworkDir = p.join(packagesDir, 'FlutterFramework');
        expect(
          File(p.join(stagedPluginDir, 'Package.swift')).readAsStringSync(),
          pluginManifest,
        );
        expect(
          p.normalize(p.join(stagedPluginDir, '..', 'FlutterFramework')),
          p.normalize(stagedFrameworkDir),
        );

        final aggregateManifest = File(
          p.join(outputDir, 'Plugins', 'Package.swift'),
        ).readAsStringSync();
        expect(aggregateManifest, contains(swiftPath(stagedPluginDir)));
        expect(aggregateManifest, contains(swiftPath(stagedFrameworkDir)));
        expect(
          aggregateManifest,
          isNot(contains(swiftPath(pluginA.swiftPackageDir))),
        );
      },
    );

    test('copies plugin packages that need interop source repair', () async {
      final plugin = makePlugin(
        'cloud_firestore',
        packageManifest: '''
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "cloud_firestore",
    dependencies: [
        .package(url: "https://example.com/firebase.git", from: "1.0.0"),
        .package(name: "firebase_core", path: "../firebase_core")
    ],
    targets: [
        .target(
            name: "cloud_firestore",
            dependencies: [.product(name: "FirebaseFirestore", package: "firebase")]
        )
    ]
)
''',
      );
      final source = File(p.join(plugin.swiftPackageDir, 'Sources', 'Plugin.m'))
        ..createSync(recursive: true);
      source.writeAsStringSync('@import FirebaseFirestore;\n');
      final firebaseCore = makePlugin('firebase_core');
      final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
      Directory(flutterXcframework).createSync(recursive: true);
      final outputDir = p.join(tmp.path, 'out');

      await _swiftPmRuntime.workspaceStager.writeGeneratedPackages(
        outputDir: outputDir,
        plugins: [plugin, firebaseCore],
        flutterXcframework: flutterXcframework,
        copyFlutterXcframework: true,
        copyPluginPackages: const {'cloud_firestore'},
        deploymentTarget: const IosDeploymentTarget(
          '15.6',
          platform: IPhoneBuildPlatform(),
        ),
      );

      final staged = File(
        p.join(
          outputDir,
          'Packages',
          'cloud_firestore',
          'ios',
          'cloud_firestore',
          'Sources',
          'Plugin.m',
        ),
      );
      expect(staged.readAsStringSync(), '@import FirebaseFirestore;\n');
      staged.writeAsStringSync('// repaired\n');
      expect(source.readAsStringSync(), '@import FirebaseFirestore;\n');
      expect(
        File(
          p.join(
            outputDir,
            'Packages',
            'cloud_firestore',
            'ios',
            'cloud_firestore',
            'Package.swift',
          ),
        ).readAsStringSync(),
        contains(
          'path: "${swiftPath(p.join(outputDir, 'Packages', 'firebase_core'))}"',
        ),
      );
    });

    test(
      'writes shared packages and the Flutter xcframework symlink',
      () async {
        final pluginA = makePlugin('plugin_a', pluginClass: 'PluginA');
        final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
        Directory(flutterXcframework).createSync(recursive: true);
        final outputDir = p.join(tmp.path, 'out');
        final frameworkPath = p.join(
          outputDir,
          'Packages',
          'FlutterFramework',
          'Flutter.xcframework',
        );
        Directory(frameworkPath).createSync(recursive: true);
        File(p.join(frameworkPath, 'stale')).writeAsStringSync('stale');

        try {
          await _swiftPmRuntime.workspaceStager.writeGeneratedPackages(
            outputDir: outputDir,
            plugins: [pluginA],
            flutterXcframework: flutterXcframework,
            copyFlutterXcframework: false,
            deploymentTarget: const IosDeploymentTarget(
              '15.6',
              platform: IPhoneBuildPlatform(),
            ),
          );
        } on FileSystemException {
          // A locked-down Windows host cannot create the link, but forcing
          // this lane must still prove it did not silently copy a directory.
          expect(Directory(frameworkPath).existsSync(), isFalse);
          return;
        }

        final frameworkManifest = File(
          p.join(outputDir, 'Packages', 'FlutterFramework', 'Package.swift'),
        );
        expect(frameworkManifest.existsSync(), isTrue);
        expect(
          frameworkManifest.readAsStringSync(),
          SwiftPmManifest.flutterFrameworkManifest(),
        );

        final link = Link(frameworkPath);
        expect(link.existsSync(), isTrue);
        expect(p.equals(link.targetSync(), flutterXcframework), isTrue);

        final pluginsManifestFile = File(
          p.join(outputDir, 'Plugins', 'Package.swift'),
        );
        expect(pluginsManifestFile.existsSync(), isTrue);
        final pluginsManifest = pluginsManifestFile.readAsStringSync();
        expect(pluginsManifest, contains('.package(name: "plugin_a", path:'));
        expect(pluginsManifest, contains('.iOS("15.6")'));

        final registrantFile = File(
          p.join(
            outputDir,
            'Plugins',
            'Sources',
            'FlutterPluginsGenerated',
            'GeneratedPluginRegistrant.swift',
          ),
        );
        expect(registrantFile.existsSync(), isTrue);
        expect(registrantFile.readAsStringSync(), contains('import plugin_a'));
      },
    );

    test('recursively copies the xcframework on Windows', () async {
      final plugin = makePlugin('plugin_a');
      final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
      final frameworkBinary = p.join(
        flutterXcframework,
        'ios-arm64',
        'Flutter.framework',
        'Flutter',
      );
      File(frameworkBinary)
        ..createSync(recursive: true)
        ..writeAsStringSync('framework binary');

      final outputDir = p.join(tmp.path, 'out');
      final copiedFramework = p.join(
        outputDir,
        'Packages',
        'FlutterFramework',
        'Flutter.xcframework',
      );
      Directory(p.dirname(copiedFramework)).createSync(recursive: true);
      File(copiedFramework).writeAsStringSync('stale file');

      await _swiftPmRuntime.workspaceStager.writeGeneratedPackages(
        outputDir: outputDir,
        plugins: [plugin],
        flutterXcframework: flutterXcframework,
        copyFlutterXcframework: true,
        deploymentTarget: const IosDeploymentTarget(
          '15.0',
          platform: IPhoneBuildPlatform(),
        ),
      );

      expect(Link(copiedFramework).existsSync(), isFalse);
      expect(
        File(
          p.join(copiedFramework, 'ios-arm64', 'Flutter.framework', 'Flutter'),
        ).readAsStringSync(),
        'framework binary',
      );
      expect(
        File(
          p.join(outputDir, 'Packages', 'FlutterFramework', 'Package.swift'),
        ).readAsStringSync(),
        SwiftPmManifest.flutterFrameworkManifest(),
      );
    });
  });

  group('SwiftPM toolset', () {
    String createTools(List<String> names, Map<String, String> into) {
      final toolsDir = Directory(p.join(tmp.path, 'LLVM Preview', 'bin'))
        ..createSync(recursive: true);
      for (final name in names) {
        into[name] = (File(p.join(toolsDir.path, name))..createSync()).path;
      }
      return toolsDir.path;
    }

    test(
      'writes an escaped external toolset with resolved LLVM paths on Windows',
      () async {
        final toolPaths = <String, String>{};
        createTools([
          'clang.exe',
          'clang++.exe',
          'llvm-libtool-darwin.exe',
          'ld64.lld.exe',
        ], toolPaths);
        final requested = <String>[];
        final outputDir = p.join(tmp.path, 'generated output');

        final toolsetPath =
            await testWindowsToolchainLookup(_windowsRuntime, (name) async {
              requested.add(name);
              return toolPaths[name];
            }).writeToolset(
              outputDir: outputDir,
              linkerPath: toolPaths['ld64.lld.exe']!,
            );

        expect(requested, [
          'llvm-libtool-darwin.exe',
          'clang.exe',
          'clang++.exe',
        ]);
        expect(toolsetPath, p.join(outputDir, 'xcross-toolset.json'));
        final contents = File(toolsetPath).readAsStringSync();
        final toolset = jsonDecode(contents) as Map<String, dynamic>;
        expect(toolset['schemaVersion'], '1.0');
        expect(contents, contains('LLVM Preview'));
        final rootPath = toolset['rootPath'] as String;
        expect(p.isAbsolute(rootPath), isTrue);
        expect(rootPath, isNot(contains(r'\')));

        final expected = {
          'cCompiler': toolPaths['clang.exe'],
          'cxxCompiler': toolPaths['clang++.exe'],
          'librarian': toolPaths['llvm-libtool-darwin.exe'],
          'linker': toolPaths['ld64.lld.exe'],
        };
        for (final entry in expected.entries) {
          final config = toolset[entry.key] as Map<String, dynamic>;
          final path = config['path'] as String;
          expect(p.isAbsolute(path), isTrue);
          expect(
            path,
            File(entry.value!).resolveSymbolicLinksSync().replaceAll(r'\', '/'),
          );
          expect(path, isNot(contains(r'\')));
        }
      },
    );

    test('writes only a librarian on Linux, falling back to llvm-ar', () async {
      final toolPaths = <String, String>{};
      createTools(['llvm-ar'], toolPaths);
      final requested = <String>[];
      final outputDir = p.join(tmp.path, 'linux output');

      final toolsetPath = await testPosixToolchainLookup(_swiftPmRuntime, (
        name,
      ) async {
        requested.add(name);
        return toolPaths[name];
      }).writeToolset(outputDir: outputDir, linkerPath: toolPaths['llvm-ar']!);

      expect(requested, ['llvm-libtool-darwin', 'llvm-ar']);
      final toolset =
          jsonDecode(File(toolsetPath).readAsStringSync())
              as Map<String, dynamic>;
      expect(toolset.keys, ['schemaVersion', 'rootPath', 'librarian']);
      expect(
        (toolset['librarian'] as Map<String, dynamic>)['path'],
        File(
          toolPaths['llvm-ar']!,
        ).resolveSymbolicLinksSync().replaceAll(r'\', '/'),
      );
    });

    test('prefers the llvm-libtool-darwin sitting next to llvm-ar', () async {
      final toolPaths = <String, String>{};
      createTools(['llvm-ar', 'llvm-libtool-darwin'], toolPaths);

      final toolsetPath =
          await testPosixToolchainLookup(
            _swiftPmRuntime,
            (name) async => name == 'llvm-ar' ? toolPaths[name] : null,
          ).writeToolset(
            outputDir: p.join(tmp.path, 'sibling output'),
            linkerPath: toolPaths['llvm-ar']!,
          );

      final toolset =
          jsonDecode(File(toolsetPath).readAsStringSync())
              as Map<String, dynamic>;
      expect(
        (toolset['librarian'] as Map<String, dynamic>)['path'],
        p
            .join(
              p.dirname(File(toolPaths['llvm-ar']!).resolveSymbolicLinksSync()),
              'llvm-libtool-darwin',
            )
            .replaceAll(r'\', '/'),
      );
    });

    test('fails when no Darwin-capable archiver exists', () {
      expect(
        testPosixToolchainLookup(
          _swiftPmRuntime,
          (name) async => null,
        ).writeToolset(
          outputDir: p.join(tmp.path, 'empty output'),
          linkerPath: 'ld64.lld',
        ),
        throwsA(isA<FlutterBuildError>()),
      );
    });

    test('target build dir prefers the native per-triple scratch layout', () {
      final scratch = Directory.systemTemp.createTempSync(
        'xcross-scratch-layout',
      );
      addTearDown(() => scratch.deleteSync(recursive: true));

      // Nothing built yet: the per-triple path the native engine uses.
      expect(
        _swiftPmRuntime.planReader.resolveTargetBuildDir(scratch.path),
        p.join(scratch.path, 'arm64-apple-ios', 'debug'),
      );

      // A swiftbuild run left out/debug behind; it is used when it is
      // the only description present.
      final out = Directory(p.join(scratch.path, 'out', 'debug'))
        ..createSync(recursive: true);
      File(p.join(out.path, 'description.json')).writeAsStringSync('{}');
      expect(
        _swiftPmRuntime.planReader.resolveTargetBuildDir(scratch.path),
        out.path,
      );

      // Once the pinned native engine has produced its own description, the
      // per-triple layout wins over the stale `out/debug`.
      final triple = Directory(p.join(scratch.path, 'arm64-apple-ios', 'debug'))
        ..createSync(recursive: true);
      File(p.join(triple.path, 'description.json')).writeAsStringSync('{}');
      expect(
        _swiftPmRuntime.planReader.resolveTargetBuildDir(scratch.path),
        triple.path,
      );
    });

    test('keeps the iOS SDK, package flags, and Windows toolset', () {
      final arguments = _windowsRuntime.buildPlan.swiftBuildArguments(
        pluginsDir: 'plugins',
        scratchPath: 'scratch',
        swiftSdksPath: 'xcross-swift-sdks',
        iosSdk: 'iPhoneOS.sdk',
        flutterFrameworkSlice: 'Flutter.xcframework/ios-arm64',
        objectiveCCompatibilityHeader: 'objective-c-compatibility.h',
        toolsetPath: 'toolset.json',
        linkerPath: '/usr/bin/ld64.lld',
      );

      expect(arguments.take(6), [
        '--package-path',
        'plugins',
        // Swift 6.4 defaults to the `swiftbuild` engine, which cannot target
        // iphoneos from a cross host; the native engine is pinned instead.
        '--build-system',
        'native',
        '--configuration',
        'debug',
      ]);
      // No DWARF, so swift-driver plans no dSYM job and needs no dsymutil.
      expect(arguments, containsAllInOrder(['-debug-info-format', 'none']));
      expect(
        arguments,
        containsAllInOrder([
          '--disable-automatic-resolution',
          '-Xswiftc',
          '-no-verify-emitted-module-interface',
        ]),
      );
      expect(
        arguments,
        containsAllInOrder([
          '-Xswiftc',
          '-Xlinker',
          '-Xswiftc',
          '-ObjC',
          '-Xswiftc',
          '-Xlinker',
          '-Xswiftc',
          '-no_objc_category_merging',
        ]),
      );
      expect(
        arguments,
        containsAllInOrder([
          '-Xswiftc',
          '-Xclang-linker',
          '-Xswiftc',
          '--ld-path=/usr/bin/ld64.lld',
        ]),
      );

      expect(
        arguments,
        containsAllInOrder([
          '--swift-sdks-path',
          'xcross-swift-sdks',
          '--swift-sdk',
          'arm64-apple-ios',
          '--toolset',
          'toolset.json',
          '--scratch-path',
          'scratch',
        ]),
      );
      expect(
        arguments,
        containsAllInOrder(['-Xswiftc', '-sdk', '-Xswiftc', 'iPhoneOS.sdk']),
      );
      expect(
        arguments,
        containsAllInOrder(['-Xcc', '-isysroot', '-Xcc', 'iPhoneOS.sdk']),
      );
      expect(
        arguments,
        containsAllInOrder([
          '-Xcc',
          '-include',
          '-Xcc',
          'objective-c-compatibility.h',
        ]),
      );
      expect(
        arguments,
        containsAllInOrder([
          '-Xswiftc',
          '-Xclang-linker',
          '-Xswiftc',
          '-isysroot',
          '-Xswiftc',
          '-Xclang-linker',
          '-Xswiftc',
          'iPhoneOS.sdk',
        ]),
      );
      expect(
        arguments,
        containsAllInOrder([
          '-Xswiftc',
          '-F',
          '-Xswiftc',
          'Flutter.xcframework/ios-arm64',
        ]),
      );
      expect(
        arguments,
        containsAllInOrder([
          '-Xcc',
          '-F',
          '-Xcc',
          'Flutter.xcframework/ios-arm64',
        ]),
      );
      expect(arguments, isNot(contains('-disable-availability-checking')));
      expect(arguments, contains('--disable-automatic-resolution'));
      expect(arguments, isNot(contains('-install_name')));
    });

    test('planned interop arguments stay stable after headers are emitted', () {
      final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
      final headers = [
        p.join(
          buildDir,
          'TransitiveInternal.build',
          'include',
          'Internal-Swift.h',
        ),
        p.join(buildDir, 'Some-Target.build', 'include', 'Some_Target-Swift.h'),
      ];
      Directory(buildDir).createSync(recursive: true);
      File(p.join(buildDir, 'description.json')).writeAsStringSync(
        jsonEncode({
          'swiftCommands': {
            for (var index = 0; index < headers.length; index++)
              'command$index': {
                'otherArguments': ['-emit-objc-header-path', headers[index]],
              },
            'duplicate': {
              'otherArguments': ['-emit-objc-header-path', headers[0]],
            },
            'noInterop': {
              'otherArguments': ['-module-name', 'NoInterop'],
            },
          },
          'clangCommands': {
            'COnly': {
              'otherArguments': ['-I', p.join(buildDir, 'COnly.build')],
            },
          },
        }),
      );
      final before = _swiftPmRuntime.planReader.plannedSwiftInteropSearchPaths(
        buildDir,
      );
      final includes = headers.map(p.dirname).toSet().toList()..sort();
      expect(
        _swiftPmRuntime.planReader.plannedSwiftInteropSearchPaths(
          p.relative(buildDir),
        ),
        before,
      );
      expect(before, [
        for (final include in includes) ...['-Xcc', '-I', '-Xcc', include],
      ]);
      for (final header in headers) {
        File(header).parent.createSync(recursive: true);
        File(header).writeAsStringSync('generated');
      }
      expect(
        _swiftPmRuntime.planReader.plannedSwiftInteropSearchPaths(buildDir),
        before,
      );
    });

    test(
      'names the planned interop targets whose header is not yet on disk',
      () {
        // On a cold build no module map exists yet, so scanning the build
        // directory finds nothing to prebuild. Reading the plan is what makes
        // the prepass see the work before the first compile.
        final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
        final headers = [
          p.join(
            buildDir,
            'PluginStore.build',
            'include',
            'PluginStore-Swift.h',
          ),
          p.join(buildDir, 'PluginAuth.build', 'include', 'PluginAuth-Swift.h'),
          p.join(buildDir, 'Unrelated.build', 'include', 'Unrelated-Swift.h'),
        ];
        Directory(buildDir).createSync(recursive: true);
        File(p.join(buildDir, 'description.json')).writeAsStringSync(
          jsonEncode({
            'swiftCommands': {
              for (var index = 0; index < headers.length; index++)
                'command$index': {
                  'otherArguments': ['-emit-objc-header-path', headers[index]],
                },
            },
          }),
        );

        expect(
          _swiftPmRuntime.consumerRepair.missingSwiftInteropTargets(
            buildDir,
            candidates: const {'PluginStore', 'PluginAuth'},
          ),
          isEmpty,
          reason: 'no module map has been written yet',
        );
        expect(
          _windowsRuntime.planReader.plannedSwiftInteropTargets(buildDir),
          ['PluginAuth', 'PluginStore', 'Unrelated'],
        );

        File(headers[1]).parent.createSync(recursive: true);
        File(headers[1]).writeAsStringSync('// generated');
        expect(
          _windowsRuntime.planReader.plannedSwiftInteropTargets(buildDir),
          ['PluginStore', 'Unrelated'],
          reason: 'a header already on disk needs no prebuild',
        );
      },
    );

    test('treats an unreadable plan as nothing to prebuild', () {
      // The prepass is an optimisation over the existing recovery, so a
      // missing plan must not fail the build.
      final buildDir = p.join(tmp.path, 'no-plan');
      Directory(buildDir).createSync(recursive: true);
      expect(
        _swiftPmRuntime.planReader.plannedSwiftInteropTargets(
          buildDir,
          candidates: const {'PluginStore'},
        ),
        isEmpty,
      );
    });

    test('skips prebuilding targets the aggregate cannot reach', () {
      // The plan lists every target in the resolved dependency graph, not
      // just the ones this build compiles. A target no product depends on is
      // never scheduled, so it can never lose the header race the prepass
      // exists to prevent, and its header never appears however many times
      // it is prebuilt. Each such prebuild is a whole `swift build` process.
      final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
      final headers = {
        'Reachable': p.join(
          buildDir,
          'Reachable.build',
          'include',
          'Reachable-Swift.h',
        ),
        'Orphan': p.join(buildDir, 'Orphan.build', 'include', 'Orphan-Swift.h'),
      };
      Directory(buildDir).createSync(recursive: true);
      File(p.join(buildDir, 'description.json')).writeAsStringSync(
        jsonEncode({
          'swiftCommands': {
            for (final entry in headers.entries)
              entry.key: {
                'otherArguments': ['-emit-objc-header-path', entry.value],
              },
          },
          'targetDependencyMap': {
            'FlutterPluginsGenerated': ['Reachable'],
            'Reachable': <String>[],
            'Orphan': <String>[],
          },
        }),
      );

      expect(
        _swiftPmRuntime.planReader.plannedSwiftInteropTargets(
          buildDir,
          candidates: const {'Reachable', 'Orphan'},
        ),
        ['Reachable'],
      );
    });

    test('prebuilds reachable internal Swift targets', () {
      final buildDir = p.join(tmp.path, 'internal-interop');
      final header = p.join(
        buildDir,
        'InternalSwiftTarget.build',
        'include',
        'InternalSwiftTarget-Swift.h',
      );
      Directory(buildDir).createSync(recursive: true);
      File(p.join(buildDir, 'description.json')).writeAsStringSync(
        jsonEncode({
          'swiftCommands': {
            'InternalSwiftTarget': {
              'otherArguments': ['-emit-objc-header-path', header],
            },
          },
          'targetDependencyMap': {
            'FlutterPluginsGenerated': ['example_plugin'],
            'example_plugin': ['InternalSwiftTarget'],
            'InternalSwiftTarget': <String>[],
          },
        }),
      );
      expect(_windowsRuntime.planReader.plannedSwiftInteropTargets(buildDir), [
        'InternalSwiftTarget',
      ]);
      expect(
        _swiftPmRuntime.planReader.plannedSwiftInteropTargets(
          buildDir,
          candidates: const {'example_plugin'},
        ),
        isEmpty,
        reason: 'POSIX still prebuilds public-product candidates only',
      );
    });

    test('prebuilds unfiltered when the plan carries no dependency map', () {
      // Reachability is an optimisation. Without a map to filter with, the
      // full set must still be prebuilt rather than silently skipping the
      // prepass and reintroducing the header race.
      final buildDir = p.join(tmp.path, 'no-map', 'arm64-apple-ios', 'debug');
      final header = p.join(
        buildDir,
        'Reachable.build',
        'include',
        'Reachable-Swift.h',
      );
      Directory(buildDir).createSync(recursive: true);
      File(p.join(buildDir, 'description.json')).writeAsStringSync(
        jsonEncode({
          'swiftCommands': {
            'Reachable': {
              'otherArguments': ['-emit-objc-header-path', header],
            },
          },
        }),
      );

      expect(
        _swiftPmRuntime.planReader.plannedSwiftInteropTargets(
          buildDir,
          candidates: const {'Reachable'},
        ),
        ['Reachable'],
      );
    });

    test('prebuilds internal headers without a dependency map', () {
      final buildDir = p.join(tmp.path, 'legacy-no-map');
      final header = p.join(
        buildDir,
        'InternalSwiftTarget.build',
        'include',
        'InternalSwiftTarget-Swift.h',
      );
      Directory(buildDir).createSync(recursive: true);
      File(p.join(buildDir, 'description.json')).writeAsStringSync(
        jsonEncode({
          'swiftCommands': {
            'InternalSwiftTarget': {
              'otherArguments': ['-emit-objc-header-path', header],
            },
          },
        }),
      );

      expect(_windowsRuntime.planReader.plannedSwiftInteropTargets(buildDir), [
        'InternalSwiftTarget',
      ]);
      expect(
        _swiftPmRuntime.planReader.plannedSwiftInteropTargets(
          buildDir,
          candidates: const {'example_plugin'},
        ),
        isEmpty,
        reason: 'keep the legacy POSIX candidate filter',
      );
      expect(
        _swiftPmRuntime.planReader.orderedInteropTargets(buildDir, [
          'InternalSwiftTarget',
        ]),
        ['InternalSwiftTarget'],
      );
    });

    test('reports whether the manifest already carries the interop paths', () {
      // llbuild replays the command lines stored in `debug.yaml` verbatim, so
      // a manifest that already names every path builds exactly what a
      // re-plan would. Re-planning anyway costs a whole extra planning
      // process on every build, incremental ones included.
      final scratch = p.join(tmp.path, 'scratch');
      Directory(scratch).createSync(recursive: true);
      final include = p.join(scratch, 'arm64-apple-ios', 'debug', 'A.build');
      final arguments = ['-Xcc', '-I', '-Xcc', include];

      expect(
        _swiftPmRuntime.planReader.manifestCarriesInteropSearchPaths(
          scratch,
          arguments,
        ),
        isFalse,
        reason: 'no manifest has been written yet',
      );

      final manifest = File(p.join(scratch, 'debug.yaml'));
      manifest.writeAsStringSync('"-I","/somewhere/else"');
      expect(
        _swiftPmRuntime.planReader.manifestCarriesInteropSearchPaths(
          scratch,
          arguments,
        ),
        isFalse,
      );

      // The manifest is JSON-quoted, so a Windows path appears escaped.
      manifest.writeAsStringSync('"-I",${jsonEncode(include)}');
      expect(
        _swiftPmRuntime.planReader.manifestCarriesInteropSearchPaths(
          scratch,
          arguments,
        ),
        isTrue,
      );
    });

    test(
      'prebuilds planned interop targets before the aggregate build',
      () async {
        final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
        final header = p.join(
          buildDir,
          'FirebaseFirestore.build',
          'include',
          'FirebaseFirestore-Swift.h',
        );
        Directory(buildDir).createSync(recursive: true);
        File(p.join(buildDir, 'description.json')).writeAsStringSync(
          jsonEncode({
            'swiftCommands': {
              'c0': {
                'otherArguments': ['-emit-objc-header-path', header],
              },
            },
          }),
        );

        final events = <String>[];
        await testPosixInteropRecovery(
          _swiftPmRuntime,
          RecordingSwiftPmInteropBuild(
            build: () async => events.add('build'),
            buildTarget: (target) async {
              events.add('target:$target');
              File(header).parent.createSync(recursive: true);
              File(header).writeAsStringSync('// generated');
            },
            repairConsumers: () async => events.add('repair'),
          ),
        ).build(
          targetBuildDir: buildDir,
          interopTargetCandidates: const {'FirebaseFirestore'},
          skipInitialRecovery: true,
        );

        expect(
          events.indexOf('target:FirebaseFirestore') < events.indexOf('build'),
          isTrue,
          reason: 'the header must exist before consumers are compiled',
        );
        expect(events.where((event) => event == 'build'), hasLength(1));
      },
    );

    test('orders Windows interop dependencies before the aggregate', () async {
      final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
      final headers = {
        for (final target in [
          'Auxiliary',
          'FlutterPluginsGenerated',
          'InternalSwiftTarget',
          'example_plugin',
        ])
          target: p.join(
            buildDir,
            '$target.build',
            'include',
            '$target-Swift.h',
          ),
      };
      Directory(buildDir).createSync(recursive: true);
      File(p.join(buildDir, 'description.json')).writeAsStringSync(
        jsonEncode({
          'swiftCommands': {
            for (final entry in headers.entries)
              entry.key: {
                'otherArguments': ['-emit-objc-header-path', entry.value],
              },
          },
          'targetDependencyMap': {
            'FlutterPluginsGenerated': ['example_plugin', 'Auxiliary'],
            'example_plugin': ['InternalSwiftTarget'],
            'InternalSwiftTarget': <String>[],
            'Auxiliary': <String>[],
          },
        }),
      );
      final planned = _swiftPmRuntime.planReader.plannedSwiftInteropTargets(
        buildDir,
        candidates: headers.keys.toSet(),
      );
      expect(planned, [
        'Auxiliary',
        'FlutterPluginsGenerated',
        'InternalSwiftTarget',
        'example_plugin',
      ]);
      expect(
        _swiftPmRuntime.planReader.orderedInteropTargets(buildDir, planned),
        ['Auxiliary', 'InternalSwiftTarget', 'example_plugin'],
      );
      final events = <String>[];
      await testWindowsInteropRecovery(
        _windowsRuntime,
        RecordingSwiftPmInteropBuild(
          build: () async {
            expect(File(headers['InternalSwiftTarget']!).existsSync(), isTrue);
            events.add('build');
          },
          buildTarget: (target) async {
            events.add('target:$target');
            final header = File(headers[target]!);
            await header.parent.create(recursive: true);
            await header.writeAsString('generated');
          },
        ),
      ).build(
        targetBuildDir: buildDir,
        interopTargetCandidates: headers.keys.toSet(),
        skipInitialRecovery: true,
      );
      expect(events, [
        'target:Auxiliary',
        'target:InternalSwiftTarget',
        'target:example_plugin',
        'build',
      ]);
    });

    test(
      'Windows prebuilds only interop targets reached by non-Swift consumers',
      () async {
        final buildDir = p.join(
          tmp.path,
          'consumed',
          'arm64-apple-ios',
          'debug',
        );
        final swiftTargets = [
          'ConsumedLeaf',
          'ConsumedRoot',
          'PublicProduct',
          'SwiftOnlyLeaf',
          'SwiftOnlyPlugin',
        ];
        final headers = {
          for (final target in swiftTargets)
            target: p.join(
              buildDir,
              '$target.build',
              'include',
              '$target-Swift.h',
            ),
        };
        Directory(buildDir).createSync(recursive: true);
        File(p.join(buildDir, 'description.json')).writeAsStringSync(
          jsonEncode({
            'swiftCommands': {
              for (final entry in headers.entries)
                entry.key: {
                  'otherArguments': ['-emit-objc-header-path', entry.value],
                },
            },
            'targetDependencyMap': {
              'FlutterPluginsGenerated': [
                'objc_plugin',
                'SwiftOnlyPlugin',
                'PublicProduct',
              ],
              'objc_plugin': ['ConsumedRoot'],
              'ConsumedRoot': ['ConsumedLeaf'],
              'ConsumedLeaf': <String>[],
              'SwiftOnlyPlugin': ['SwiftOnlyLeaf'],
              'SwiftOnlyLeaf': <String>[],
              'PublicProduct': <String>[],
            },
          }),
        );

        final events = <String>[];
        final session = RecordingSwiftPmInteropBuild(
          build: () async => events.add('build'),
          buildTarget: (target) async {
            events.add('target:$target');
            final header = File(headers[target]!);
            await header.parent.create(recursive: true);
            await header.writeAsString('generated');
          },
        );
        await testWindowsInteropRecovery(_windowsRuntime, session).build(
          targetBuildDir: buildDir,
          interopTargetCandidates: const {'PublicProduct'},
          skipInitialRecovery: true,
        );

        expect(events, [
          'target:ConsumedLeaf',
          'target:PublicProduct',
          'target:ConsumedRoot',
          'build',
        ]);
        expect(session.invocations, [
          ['ConsumedLeaf', 'PublicProduct'],
          ['ConsumedRoot'],
        ]);
      },
    );

    test('Windows host policy keeps every planned target without a map', () {
      expect(
        _windowsRuntime.hostPolicy.selectInteropTargets(
          const ['Alpha', 'Beta'],
          const {'Alpha'},
          null,
        ),
        ['Alpha', 'Beta'],
      );
      expect(
        _windowsRuntime.hostPolicy.selectInteropTargets(
          const ['Alpha', 'Beta', 'Gamma'],
          const {'Alpha'},
          const {'Gamma'},
        ),
        ['Alpha', 'Gamma'],
      );
    });

    test('layers independent interop targets into shared invocations', () {
      expect(
        SwiftPmPlanReader.layerTargetsByDependencies(
          {
            'Top': ['Middle', 'Other'],
            'Middle': ['Bridge'],
            'Bridge': ['Bottom'],
            'Bottom': <String>[],
            'Other': <String>[],
          },
          const ['Top', 'Middle', 'Bottom', 'Other'],
        ),
        [
          ['Other', 'Bottom'],
          ['Middle'],
          ['Top'],
        ],
      );
      expect(
        SwiftPmPlanReader.layerTargetsByDependencies(null, const ['B', 'A']),
        [
          ['B'],
          ['A'],
        ],
      );
    });

    test('rejects missing and malformed Swift planning descriptions', () {
      final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
      Directory(buildDir).createSync(recursive: true);
      final description = File(p.join(buildDir, 'description.json'));
      void check() => expect(
        () =>
            _swiftPmRuntime.planReader.plannedSwiftInteropSearchPaths(buildDir),
        throwsA(isA<FlutterBuildError>()),
      );
      check();
      for (final value in [
        'not json',
        '{}',
        jsonEncode({'swiftCommands': <Object?>[]}),
        jsonEncode({
          'swiftCommands': {
            'bad': {
              'otherArguments': [1],
            },
          },
        }),
        jsonEncode({
          'swiftCommands': {
            'bad': {
              'otherArguments': ['-emit-objc-header-path'],
            },
          },
        }),
        jsonEncode({
          'swiftCommands': {
            'bad': {
              'otherArguments': ['-emit-objc-header-path', 'relative-Swift.h'],
            },
          },
        }),
        jsonEncode({
          'swiftCommands': {
            'bad': {
              'otherArguments': [
                '-emit-objc-header-path',
                p.join(tmp.path, 'outside-Swift.h'),
              ],
            },
          },
        }),
      ]) {
        description.writeAsStringSync(value);
        check();
      }
      description.writeAsStringSync(
        jsonEncode({'swiftCommands': <String, Object?>{}}),
      );
      expect(
        _swiftPmRuntime.planReader.plannedSwiftInteropSearchPaths(buildDir),
        isEmpty,
      );
    });

    test(
      'planned missing targets preserve aggregate-first recovery ordering',
      () async {
        final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
        for (final target in ['PluginStore', 'PluginAuth']) {
          final include = Directory(
            p.join(buildDir, '$target.build', 'include'),
          );
          include.createSync(recursive: true);
          File(
            p.join(include.path, 'module.modulemap'),
          ).writeAsStringSync('module $target { header "$target-Swift.h" }');
        }
        var attempts = 0;
        final events = <String>[];
        await testWindowsInteropRecovery(
          _windowsRuntime,
          RecordingSwiftPmInteropBuild(
            build: () async {
              events.add('build${++attempts}');
              if (attempts == 1) {
                throw StateError("'PluginAuth-Swift.h' file not found");
              }
            },
            buildTarget: (target) async {
              events.add(target);
              File(
                p.join(buildDir, '$target.build', 'include', '$target-Swift.h'),
              ).writeAsStringSync('generated');
            },
            repairConsumers: () async => events.add('repair'),
          ),
        ).build(
          targetBuildDir: buildDir,
          interopTargetCandidates: const {'PluginStore', 'PluginAuth'},
          skipInitialRecovery: true,
        );
        expect(events, [
          'repair',
          'build1',
          'PluginAuth',
          'PluginStore',
          'repair',
          'build2',
        ]);
      },
    );

    test(
      'does not rebuild interop targets after an unrelated compile error',
      () async {
        final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
        final include = Directory(p.join(buildDir, 'Plugin.build', 'include'))
          ..createSync(recursive: true);
        File(
          p.join(include.path, 'module.modulemap'),
        ).writeAsStringSync('module Plugin { header "Plugin-Swift.h" }');
        var attempts = 0;
        await expectLater(
          testWindowsInteropRecovery(
            _windowsRuntime,
            RecordingSwiftPmInteropBuild(
              build: () {
                attempts++;
                return Future.error(StateError('syntax error in user source'));
              },
              buildTarget: (_) async =>
                  fail('unrelated errors must not recover'),
            ),
          ).build(
            targetBuildDir: buildDir,
            interopTargetCandidates: const {'Plugin'},
            skipInitialRecovery: true,
          ),
          throwsA(isA<StateError>()),
        );
        expect(attempts, 1);
      },
    );

    test(
      'planned builds retain Windows emitted-header recovery fallback',
      () async {
        final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
        final include = Directory(
          p.join(buildDir, 'OtherSwift.build', 'include'),
        );
        include.createSync(recursive: true);
        File(p.join(buildDir, 'description.json')).writeAsStringSync(
          jsonEncode({
            'swiftCommands': {
              'OtherSwift': {
                'otherArguments': [
                  '-emit-objc-header-path',
                  p.join(include.path, 'OtherSwift-Swift.h'),
                ],
              },
            },
            'targetDependencyMap': {
              'FlutterPluginsGenerated': <String>[],
              'OtherSwift': <String>[],
            },
          }),
        );
        final flags = _swiftPmRuntime.planReader.plannedSwiftInteropSearchPaths(
          buildDir,
        );
        var attempts = 0;
        final events = <String>[];
        await testWindowsInteropRecovery(
          _windowsRuntime,
          RecordingSwiftPmInteropBuild(
            build: () async {
              events.add('build${++attempts}');
              expect(
                _swiftPmRuntime.planReader.plannedSwiftInteropSearchPaths(
                  buildDir,
                ),
                flags,
              );
              if (attempts != 1) return;
              File(
                p.join(include.path, 'OtherSwift-Swift.h'),
              ).writeAsStringSync('generated');
              throw StateError("'OtherSwift-Swift.h' file not found");
            },
            buildTarget: (_) async => fail('no target should be prebuilt'),
            repairConsumers: () async => events.add('repair'),
          ),
        ).build(
          targetBuildDir: buildDir,
          interopTargetCandidates: const {},
          skipInitialRecovery: true,
        );
        expect(events, ['repair', 'build1', 'repair', 'build2']);
      },
    );

    test('passes interop include dirs on POSIX hosts', () {
      final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
      // A Swift target that has been built: interop header emitted.
      final built = p.join(buildDir, 'Impl.build', 'include');
      Directory(built).createSync(recursive: true);
      File(p.join(built, 'Impl-Swift.h')).writeAsStringSync('// generated');
      // A target with no interop header contributes no search path.
      Directory(
        p.join(buildDir, 'PlainObjC.build', 'include'),
      ).createSync(recursive: true);

      expect(_swiftPmRuntime.planReader.swiftInteropSearchPaths(buildDir), [
        '-Xcc',
        '-I',
        '-Xcc',
        built,
      ]);
      // Nothing is built yet on a clean build.
      expect(
        _swiftPmRuntime.planReader.swiftInteropSearchPaths(
          p.join(tmp.path, 'absent'),
        ),
        isEmpty,
      );

      expect(
        _swiftPmRuntime.buildPlan.swiftBuildArguments(
          pluginsDir: 'plugins',
          scratchPath: 'scratch',
          swiftSdksPath: 'xcross-swift-sdks',
          iosSdk: 'iPhoneOS.sdk',
          flutterFrameworkSlice: 'Flutter.xcframework/ios-arm64',

          interopSearchPaths: ['-Xcc', '-I', '-Xcc', built],
        ),
        containsAllInOrder(['-Xcc', '-I', '-Xcc', built]),
      );
    });

    test(
      'repairs transitive imports exposed by generated Swift headers',
      () async {
        final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
        final include = p.join(buildDir, 'FirebaseFirestore.build', 'include');
        Directory(include).createSync(recursive: true);
        File(p.join(include, 'FirebaseFirestore-Swift.h')).writeAsStringSync('''
@import FirebaseFirestoreInternal;
''');
        final consumer = p.join(tmp.path, 'cloud_firestore');
        final source = File(p.join(consumer, 'Sources', 'Plugin.m'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
@import FirebaseFirestore;
void registerPlugin(void) {}
''');
        final unrelated = File(p.join(consumer, 'Sources', 'Other.m'))
          ..writeAsStringSync('@import FirebaseCore;\n');

        await _swiftPmRuntime.consumerRepair.repairSwiftInteropConsumers(
          targetBuildDir: buildDir,
          consumerProducts: {
            consumer: const {'FirebaseFirestore'},
          },
        );
        await _swiftPmRuntime.consumerRepair.repairSwiftInteropConsumers(
          targetBuildDir: buildDir,
          consumerProducts: {
            consumer: const {'FirebaseFirestore'},
          },
        );

        expect(source.readAsStringSync(), '''
@import FirebaseFirestore;
@import FirebaseFirestoreInternal;
void registerPlugin(void) {}
''');
        expect(unrelated.readAsStringSync(), '@import FirebaseCore;\n');
      },
    );

    test(
      'prebuilds a Swift target whose generated header is missing',
      () async {
        final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
        final include = p.join(buildDir, 'FirebaseFirestore.build', 'include');
        Directory(include).createSync(recursive: true);
        File(p.join(include, 'module.modulemap')).writeAsStringSync('''
module FirebaseFirestore {
  header "FirebaseFirestore-Swift.h"
}
''');
        final unrelated = p.join(buildDir, 'FirebaseAI.build', 'include');
        Directory(unrelated).createSync(recursive: true);
        File(p.join(unrelated, 'module.modulemap')).writeAsStringSync('''
module FirebaseAI {
  header "FirebaseAI-Swift.h"
}
''');
        var attempts = 0;
        final prebuilt = <String>[];
        final events = <String>[];

        await testPosixInteropRecovery(
          _swiftPmRuntime,
          RecordingSwiftPmInteropBuild(
            build: () async {
              events.add('build');
              attempts++;
            },
            buildTarget: (target) async {
              events.add('target');
              prebuilt.add(target);
              File(
                p.join(include, 'FirebaseFirestore-Swift.h'),
              ).writeAsStringSync('// generated');
            },
            repairConsumers: () async => events.add('repair'),
          ),
        ).build(
          targetBuildDir: buildDir,
          interopTargetCandidates: const {'FirebaseFirestore'},
        );

        expect(prebuilt, ['FirebaseFirestore']);
        expect(attempts, 1);
        expect(events, ['repair', 'target', 'repair', 'build']);
      },
    );

    test(
      'prebuilds and retries when a build exposes a missing header',
      () async {
        final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
        final include = p.join(buildDir, 'FirebaseFirestore.build', 'include');
        var attempts = 0;
        final events = <String>[];

        await testPosixInteropRecovery(
          _swiftPmRuntime,
          RecordingSwiftPmInteropBuild(
            build: () async {
              attempts++;
              events.add('build$attempts');
              if (attempts != 1) return;
              Directory(include).createSync(recursive: true);
              File(p.join(include, 'module.modulemap')).writeAsStringSync('''
module FirebaseFirestore {
  header "$include/FirebaseFirestore-Swift.h"
}
''');
              throw StateError(
                "header '$include/FirebaseFirestore-Swift.h' not found",
              );
            },
            buildTarget: (target) async {
              events.add('target');
              expect(target, 'FirebaseFirestore');
              File(
                p.join(include, 'FirebaseFirestore-Swift.h'),
              ).writeAsStringSync('// generated');
            },
            repairConsumers: () async => events.add('repair'),
          ),
        ).build(
          targetBuildDir: buildDir,
          interopTargetCandidates: const {'FirebaseFirestore'},
        );

        expect(attempts, 2);
        expect(events, ['repair', 'build1', 'target', 'repair', 'build2']);
      },
    );

    test('does not retry a failure that emits no interop header', () async {
      var attempts = 0;

      await expectLater(
        testPosixInteropRecovery(
          _swiftPmRuntime,
          RecordingSwiftPmInteropBuild(
            build: () {
              attempts++;
              return Future<void>.error(StateError('real compile failure'));
            },
            buildTarget: (_) async => fail('no target should be prebuilt'),
          ),
        ).build(
          targetBuildDir: p.join(tmp.path, 'arm64-apple-ios', 'debug'),
          interopTargetCandidates: const {'FirebaseFirestore'},
        ),
        throwsStateError,
      );

      expect(attempts, 1);
    });

    test(
      'prebuilds a newly exposed missing header despite truncated diagnostics',
      () async {
        final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
        final include = p.join(buildDir, 'FirebaseFirestore.build', 'include');
        var attempts = 0;

        await testPosixInteropRecovery(
          _swiftPmRuntime,
          RecordingSwiftPmInteropBuild(
            build: () async {
              attempts++;
              if (attempts != 1) return;
              Directory(include).createSync(recursive: true);
              File(p.join(include, 'module.modulemap')).writeAsStringSync('''
module FirebaseFirestore {
  header "FirebaseFirestore-Swift.h"
}
''');
              throw StateError('command failed without compiler output');
            },
            buildTarget: (target) async {
              expect(target, 'FirebaseFirestore');
              File(
                p.join(include, 'FirebaseFirestore-Swift.h'),
              ).writeAsStringSync('// generated');
            },
          ),
        ).build(
          targetBuildDir: buildDir,
          interopTargetCandidates: const {'FirebaseFirestore'},
        );

        expect(attempts, 2);
      },
    );

    test(
      'does not retry an unrelated POSIX failure as headers build',
      () async {
        final buildDir = p.join(tmp.path, 'arm64-apple-ios', 'debug');
        var attempts = 0;

        await expectLater(
          testPosixInteropRecovery(
            _swiftPmRuntime,
            RecordingSwiftPmInteropBuild(
              build: () {
                attempts++;
                final include = p.join(buildDir, 'OtherSwift.build', 'include');
                Directory(include).createSync(recursive: true);
                File(
                  p.join(include, 'OtherSwift-Swift.h'),
                ).writeAsStringSync('// generated');
                return Future<void>.error(
                  StateError('unrelated compile failure'),
                );
              },
              buildTarget: (_) async => fail('no target should be prebuilt'),
            ),
          ).build(
            targetBuildDir: buildDir,
            interopTargetCandidates: const {'FirebaseFirestore'},
          ),
          throwsStateError,
        );

        expect(attempts, 1);
      },
    );

    test('drops Clang implicit module locks only on Windows', () {
      List<String> argumentsFor(SwiftPmRuntime runtime) =>
          runtime.buildPlan.swiftBuildArguments(
            pluginsDir: 'plugins',
            scratchPath: 'scratch',
            swiftSdksPath: 'xcross-swift-sdks',
            iosSdk: 'iPhoneOS.sdk',
            flutterFrameworkSlice: 'Flutter.xcframework/ios-arm64',
            toolsetPath: 'toolset.json',
          );

      // Clang's lock protocol hangs competing frontends on Windows, so
      // the C/Objective-C targets and Swift's own frontend both opt out.
      expect(
        argumentsFor(_windowsRuntime),
        containsAllInOrder([
          '-Xcc',
          '-Xclang',
          '-Xcc',
          '-fno-implicit-modules-use-lock',
          '-Xswiftc',
          '-Xcc',
          '-Xswiftc',
          '-Xclang',
          '-Xswiftc',
          '-Xcc',
          '-Xswiftc',
          '-fno-implicit-modules-use-lock',
        ]),
      );
      // POSIX hosts keep the lock so parallel builds still share work.
      expect(
        argumentsFor(_swiftPmRuntime),
        isNot(contains('-fno-implicit-modules-use-lock')),
      );
    });

    test(
      'resolves with package options before the resolve subcommand',
      () async {
        expect(
          _swiftPmRuntime.processPolicy.swiftResolveArguments(
            pluginsDir: 'plugins',
            scratchPath: 'scratch',
            swiftSdksPath: 'xcross-swift-sdks',
            toolsetPath: 'toolset.json',
          ),
          [
            'package',
            ..._swiftPmRuntime.processPolicy.hostManifestArguments(),
            '--package-path',
            'plugins',
            '--scratch-path',
            'scratch',
            '--swift-sdks-path',
            'xcross-swift-sdks',
            '--swift-sdk',
            'arm64-apple-ios',
            '--toolset',
            'toolset.json',
            'resolve',
          ],
        );
        expect(await _windowsRuntime.processPolicy.swiftProcessEnvironment(), {
          ...SwiftPmProcessPolicy.nonInteractiveGitEnvironment,
          'GIT_CONFIG_COUNT': '6',
          'GIT_CONFIG_KEY_0': 'credential.helper',
          // Two quotes, not the empty string: git rejects a genuinely empty
          // GIT_CONFIG_VALUE_* and would then fail every command.
          'GIT_CONFIG_VALUE_0': '""',
          'GIT_CONFIG_KEY_1': 'credential.interactive',
          'GIT_CONFIG_VALUE_1': 'false',
          // Abort a stalled fetch instead of holding it open forever.
          'GIT_CONFIG_KEY_2': 'http.lowSpeedLimit',
          'GIT_CONFIG_VALUE_2': '1024',
          'GIT_CONFIG_KEY_3': 'http.lowSpeedTime',
          'GIT_CONFIG_VALUE_3': '60',
          'GIT_CONFIG_KEY_4': 'core.symlinks',
          'GIT_CONFIG_VALUE_4': 'false',
          'GIT_CONFIG_KEY_5': 'core.longpaths',
          'GIT_CONFIG_VALUE_5': 'true',
          'EXPERIMENTAL_SPM_BUILDS': '1',
        });
      },
    );

    test('refuses interactive git credential prompts on every host', () async {
      // A prompt no one can answer is how a CI build hangs for hours
      // instead of failing on the dependency it could not read.
      for (final runtime in [_windowsRuntime, _swiftPmRuntime]) {
        final environment = await runtime.processPolicy
            .swiftProcessEnvironment();
        expect(environment, isNotNull);
        expect(environment['GIT_TERMINAL_PROMPT'], '0');
        expect(environment['GIT_ASKPASS'], '');
        expect(environment['SSH_ASKPASS'], '');
        expect(environment['SSH_ASKPASS_REQUIRE'], 'never');
        expect(environment['GCM_INTERACTIVE'], 'never');
        expect(environment['GCM_PROVIDER'], 'none');
        expect(environment['GIT_SSH_COMMAND'], contains('BatchMode=yes'));
      }
    });

    test('keeps Windows-only SwiftPM settings off other hosts', () async {
      final posix = await _swiftPmRuntime.processPolicy
          .swiftProcessEnvironment();
      expect(posix.containsKey('EXPERIMENTAL_SPM_BUILDS'), isFalse);
      // Only the credential settings, never the Windows symlink lane.
      expect(posix['GIT_CONFIG_COUNT'], '4');
      expect(posix['GIT_CONFIG_KEY_0'], 'credential.helper');
      expect(posix['GIT_CONFIG_VALUE_0'], '""');
      expect(posix['GIT_CONFIG_KEY_1'], 'credential.interactive');
      expect(posix.containsKey('GIT_CONFIG_KEY_4'), isFalse);
      expect(
        [posix['GIT_CONFIG_KEY_2'], posix['GIT_CONFIG_KEY_3']],
        ['http.lowSpeedLimit', 'http.lowSpeedTime'],
      );
    });

    test('prepends bundled xcrun to the configured child PATH', () async {
      final directory = await Directory.systemTemp.createTemp('xcross-path-');
      addTearDown(() async {
        await directory.delete(recursive: true);
      });
      final executable = p.join(directory.path, 'xcross.exe');
      File(p.join(directory.path, 'xcrun.exe')).writeAsStringSync('shim');
      final runtime = testWindowsSwiftPmRuntime(
        environment: const {'PATH': r'C:\configured\tools'},
      );

      final environment = await runtime.processPolicy.swiftProcessEnvironment(
        executable: executable,
      );
      expect(
        environment['PATH'],
        '${directory.path};${r'C:\configured\tools'}',
      );
    });

    test(
      'reads the Windows Path key without losing configured tools',
      () async {
        final directory = await Directory.systemTemp.createTemp('xcross-path-');
        addTearDown(() async {
          await directory.delete(recursive: true);
        });
        File(p.join(directory.path, 'xcrun.exe')).writeAsStringSync('shim');
        final runtime = testWindowsSwiftPmRuntime(
          environment: const {'Path': r'C:\configured\tools'},
        );

        final environment = await runtime.processPolicy.swiftProcessEnvironment(
          executable: p.join(directory.path, 'xcross.exe'),
        );
        expect(
          environment['PATH'],
          '${directory.path};${r'C:\configured\tools'}',
        );
      },
    );

    test('disables every configured git credential helper', () async {
      // A system-wide helper (Git Credential Manager on the Windows
      // runners) is consulted before GIT_TERMINAL_PROMPT applies and can
      // block on UI of its own, so the helper list has to be reset too.
      for (final runtime in [_windowsRuntime, _swiftPmRuntime]) {
        final environment = await runtime.processPolicy
            .swiftProcessEnvironment();
        final count = int.parse(environment['GIT_CONFIG_COUNT']!);
        final settings = {
          for (var index = 0; index < count; index++)
            environment['GIT_CONFIG_KEY_$index']:
                environment['GIT_CONFIG_VALUE_$index'],
        };
        // `""` is the config-file spelling of an empty value, which is what
        // resets an inherited helper list.
        expect(settings['credential.helper'], '""');
        expect(settings['credential.interactive'], 'false');
        // Every declared key must have a value: git refuses to parse an
        // empty one and would fail every command this build runs.
        for (var index = 0; index < count; index++) {
          expect(environment['GIT_CONFIG_VALUE_$index'], isNotEmpty);
        }
      }
    });
  });

  group('Objective-C compatibility header', () {
    test('imports Foundation only for Objective-C compilations', () async {
      final path = await _swiftPmRuntime.buildPlan
          .writeObjectiveCCompatibilityHeader(tmp.path);
      expect(
        File(path).readAsStringSync(),
        '#ifdef __OBJC__\n#import <Foundation/Foundation.h>\n#endif\n',
      );
    });
  });

  group('open apple macros', () {
    test('threads the macro server arguments onto the frontend', () {
      const macros = [
        '-Xswiftc',
        '-plugin-path',
        '-Xswiftc',
        'toolchain/host/plugins',
        '-Xswiftc',
        '-load-plugin-executable',
        '-Xswiftc',
        'server#PreviewsMacros',
      ];
      final arguments = _swiftPmRuntime.buildPlan.swiftBuildArguments(
        pluginsDir: 'plugins',
        scratchPath: 'scratch',
        swiftSdksPath: 'xcross-swift-sdks',
        iosSdk: 'iPhoneOS.sdk',
        flutterFrameworkSlice: 'Flutter.xcframework/ios-arm64',
        macroServerArguments: macros,
      );
      expect(arguments, containsAllInOrder(macros));
      expect(
        arguments.indexOf('-plugin-path'),
        lessThan(arguments.indexOf('-sdk')),
      );
      expect(
        _swiftPmRuntime.buildPlan.swiftBuildArguments(
          pluginsDir: 'plugins',
          scratchPath: 'scratch',
          swiftSdksPath: 'xcross-swift-sdks',
          iosSdk: 'iPhoneOS.sdk',
          flutterFrameworkSlice: 'Flutter.xcframework/ios-arm64',
        ),
        isNot(contains('-load-plugin-executable')),
      );
    });
  });

  group('built dylibs', () {
    test('returns the aggregate and every produced dynamic library', () async {
      final output = Directory(p.join(tmp.path, 'debug'))..createSync();
      final aggregate = File(
        p.join(output.path, 'libFlutterPluginsGenerated.dylib'),
      )..writeAsBytesSync(_emptyMachO());
      final dependency = File(p.join(output.path, 'libDynamicPlugin.dylib'))
        ..writeAsBytesSync(_emptyMachO());
      File(
        p.join(output.path, 'libStaticPlugin.a'),
      ).writeAsStringSync('static');

      final result = await _swiftPmRuntime.assembly.discoverAndRewriteDylibs(
        output.path,
      );

      expect(result.libraryPath, p.absolute(aggregate.path));
      expect(result.dylibPaths, {
        p.absolute(aggregate.path),
        p.absolute(dependency.path),
      });
    });

    test('returns dynamic binary frameworks for embedding', () async {
      final output = Directory(p.join(tmp.path, 'debug'))..createSync();
      File(
        p.join(output.path, 'libFlutterPluginsGenerated.dylib'),
      ).writeAsBytesSync(_emptyMachO());
      Uint8List machO(int fileType) {
        final bytes = _emptyMachO();
        ByteData.sublistView(bytes).setUint32(12, fileType, Endian.little);
        return bytes;
      }

      Uint8List universal(int fileType) {
        final slice = machO(fileType);
        final bytes = Uint8List(4096 + slice.length);
        ByteData.sublistView(bytes)
          ..setUint32(0, 0xcafebabe)
          ..setUint32(4, 1)
          ..setUint32(8, 0x0100000c)
          ..setUint32(16, 4096)
          ..setUint32(20, slice.length);
        bytes.setRange(4096, bytes.length, slice);
        return bytes;
      }

      String framework(String name, Uint8List binary) {
        final directory = Directory(p.join(output.path, '$name.framework'))
          ..createSync();
        File(p.join(directory.path, name)).writeAsBytesSync(binary);
        return p.absolute(directory.path);
      }

      final thinDynamic = framework('ThinDynamic', machO(6));
      final universalDynamic = framework('UniversalDynamic', universal(6));
      framework('ThinStatic', machO(1));
      framework('UniversalStatic', universal(1));
      Directory(p.join(output.path, 'Empty.framework')).createSync();

      final result = await _swiftPmRuntime.assembly.discoverAndRewriteDylibs(
        output.path,
      );

      expect(result.frameworkPaths, [thinDynamic, universalDynamic]);
    });
  });

  group('build', () {
    test(
      'returns null and writes nothing when there are no SPM plugins',
      () async {
        final workspace = SwiftPmWorkspace.forProject(
          tmp.path,
          environment: {'XCROSS_CACHE_DIR': tmp.path},
          policy: _swiftPmRuntime.targetPolicy,
        );

        final result = await _plugins.build(
          projectRoot: tmp.path,
          workspace: workspace,
          plugins: const [],
          flutterXcframework: p.join(tmp.path, 'Flutter.xcframework'),
          deploymentTarget: const IosDeploymentTarget(
            '15.0',
            platform: IPhoneBuildPlatform(),
          ),
          artifactJunctionCapabilityResolver: () async =>
              fail('must not resolve capabilities without SPM plugins'),
        );

        expect(result, isNull);
        expect(Directory(workspace.packages).existsSync(), isFalse);
      },
    );

    test(
      'returns null when plugins exist but none use Swift Package Manager',
      () async {
        final podspecOnly = p.join(tmp.path, 'plugin_pod');
        Directory(p.join(podspecOnly, 'ios')).createSync(recursive: true);
        File(
          p.join(podspecOnly, 'ios', 'plugin_pod.podspec'),
        ).writeAsStringSync('');
        final plugin = IosPlugin(
          fileSystem: _swiftPmRuntime.host.fileSystem,
          name: 'plugin_pod',
          packageRoot: podspecOnly,
        );
        final workspace = SwiftPmWorkspace.forProject(
          tmp.path,
          environment: {'XCROSS_CACHE_DIR': tmp.path},
          policy: _swiftPmRuntime.targetPolicy,
        );

        final result = await _plugins.build(
          projectRoot: tmp.path,
          workspace: workspace,
          plugins: [plugin],
          flutterXcframework: p.join(tmp.path, 'Flutter.xcframework'),
          deploymentTarget: const IosDeploymentTarget(
            '15.0',
            platform: IPhoneBuildPlatform(),
          ),
          artifactJunctionCapabilityResolver: () async =>
              fail('must not resolve capabilities for ObjC-only plugins'),
        );

        expect(result, isNull);
        expect(Directory(workspace.packages).existsSync(), isFalse);
      },
    );

    test('invokes the capability resolver once for SPM plugins', () async {
      final plugin = makePlugin('resolver_plugin');
      final workspace = SwiftPmWorkspace.forProject(
        tmp.path,
        environment: {'XCROSS_CACHE_DIR': tmp.path},
        policy: _swiftPmRuntime.targetPolicy,
      );
      var resolverCalls = 0;

      await expectLater(
        _plugins.build(
          projectRoot: tmp.path,
          workspace: workspace,
          plugins: [plugin],
          flutterXcframework: p.join(tmp.path, 'Flutter.xcframework'),
          deploymentTarget: const IosDeploymentTarget(
            '15.0',
            platform: IPhoneBuildPlatform(),
          ),
          artifactJunctionCapabilityResolver: () {
            resolverCalls++;
            throw StateError('resolver reached');
          },
        ),
        throwsStateError,
      );

      expect(resolverCalls, 1);
    });
  });

  group('Swift SDK / toolchain mismatch', () {
    test('replaces the raw compiler diagnostic with actionable guidance', () {
      expect(
        () => _swiftPmRuntime.sourceRepair.buildTranslatingSdkMismatch(
          () => throw CliError(
            "error: failed to build module 'UIKit'; "
            "$swiftSdkMismatchMarker (the SDK is built with 'Apple Swift "
            "version 6.3.2', while this compiler is 'Swift version 6.3.2 "
            "(swift-6.3.2-RELEASE)'). Please select a toolchain which "
            'matches the SDK.',
          ),
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            allOf(contains('xcross sdk install'), contains('switching Swift')),
          ),
        ),
      );
    });

    test('leaves every other build failure untouched', () {
      expect(
        () => _swiftPmRuntime.sourceRepair.buildTranslatingSdkMismatch(
          () => throw CliError('error: use of unresolved identifier'),
        ),
        throwsA(
          isA<CliError>().having(
            (error) => error.message,
            'message',
            contains('unresolved identifier'),
          ),
        ),
      );
    });
  });
}

Uint8List _emptyMachO() {
  final bytes = Uint8List(32);
  ByteData.sublistView(bytes).setUint32(0, 0xfeedfacf, Endian.little);
  return bytes;
}
