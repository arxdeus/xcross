import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/errors.dart';

String swiftPath(String path) => p.absolute(path).replaceAll(r'\', '/');

void main() {
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
  }) {
    final packageRoot = p.join(tmp.path, name);
    Directory(p.join(packageRoot, 'ios', name)).createSync(recursive: true);
    File(
      p.join(packageRoot, 'ios', name, 'Package.swift'),
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

    return IosPlugin(name: name, packageRoot: packageRoot);
  }

  group('flutterFrameworkManifest', () {
    test('matches the exact wrapper manifest', () {
      expect(GeneratedPluginsPackage.flutterFrameworkManifest(), '''
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
    test('includes every plugin package dependency and hyphenated product', () {
      final pluginA = makePlugin('plugin_a', pluginClass: 'PluginA');
      final pluginB = makePlugin('plugin_b');
      final frameworkDir = p.join(tmp.path, 'FlutterFramework');

      const target = IosDeploymentTarget('15.6');
      final manifest = GeneratedPluginsPackage.pluginsManifest(
        [pluginA, pluginB],
        frameworkDir,
        deploymentTarget: target,
      );

      expect(manifest, contains('name: "FlutterPluginsGenerated"'));
      expect(manifest, contains('.iOS("15.6")'));
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

      final manifest = GeneratedPluginsPackage.pluginsManifest(
        [pluginA],
        frameworkDir,
        deploymentTarget: IosDeploymentTarget.fallback,
      );

      expect(manifest, isNot(contains(r'\')));
    });
  });

  group('normalizeLinkerFlags', () {
    test('normalizes SwiftPM Wl linker flags', () {
      expect(
        GeneratedPluginsPackage.normalizeLinkerFlags(
          '.unsafeFlags(["-Wl,-undefined,dynamic_lookup"])',
        ),
        '.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", '
        '"dynamic_lookup"])',
      );
      expect(
        GeneratedPluginsPackage.normalizeLinkerFlags(
          '.unsafeFlags(["-O3", "-Wl,-rpath,@loader_path"])',
        ),
        '.unsafeFlags(["-O3", "-Xlinker", "-rpath", "-Xlinker", '
        '"@loader_path"])',
      );

      const escaped = r'.unsafeFlags(["-Wl,-rpath,\"quoted\""])';
      expect(GeneratedPluginsPackage.normalizeLinkerFlags(escaped), escaped);
    });
  });

  group('normalizeHostManifest', () {
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
      final out = GeneratedPluginsPackage.normalizeHostManifest(input);
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
        GeneratedPluginsPackage.normalizeHostManifest(input),
        contains('import CRT\n'),
      );
    });

    test('drops Foundation String(cString:encoding:) in manifests', () {
      const input =
          'if let env = env, String(cString: env, encoding: .utf8) == "1"';
      expect(
        GeneratedPluginsPackage.normalizeHostManifest(input),
        'if let env = env, String(cString: env) == "1"',
      );
    });

    test('normalization is idempotent', () {
      const input = '''
#elseif canImport(MSVCRT)
import MSVCRT
''';
      final normalized = GeneratedPluginsPackage.normalizeHostManifest(input);
      expect(
        GeneratedPluginsPackage.normalizeHostManifest(normalized),
        normalized,
      );
      expect('import CRT'.allMatches(normalized), hasLength(1));
    });

    test('preserves a binary product name for its source fallback', () {
      const input = '''
var products: [Product] = [.library(name: "PublicSDK", targets: ["PublicSDK"])]
var targets: [Target] = [.binaryTarget(name: "PublicSDK", url: "SDK.xcframework.zip", checksum: "abc")]
if getenv("EXPERIMENTAL_SPM_BUILDS") != nil {
    targets.append(.target(name: "SourceSDK", path: "Sources"))
    products.append(.library(name: "SourceProduct", type: .dynamic, targets: ["SourceSDK"]))
}
''';
      final normalized = GeneratedPluginsPackage.normalizeHostManifest(input);
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
        contains('.target(name: "PublicSDK", path: "Sources")'),
      );
      expect(
        normalized,
        contains(
          '.library(name: "PublicSDK", type: .dynamic, '
          'targets: ["PublicSDK"])',
        ),
      );
      expect(
        GeneratedPluginsPackage.normalizeHostManifest(normalized),
        normalized,
      );
    });

    test('still normalizes linker flags', () {
      expect(
        GeneratedPluginsPackage.normalizeHostManifest(
          '.unsafeFlags(["-Wl,-rpath,@loader_path"])',
        ),
        '.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path"])',
      );
    });
  });

  group('normalizeHostSwiftSource', () {
    test('blanks previews while retaining runtime code and non-code text', () {
      const input = r'''
let before = true
// #Preview { broken( }
let text = "#Preview { broken( }"
let escaped = "quote: \" and brace }"
let multiline = """
#Preview { broken( }
"""
let raw = #"#Preview { broken( }"#
/* outer { /* #Preview { */ } */
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

      final output = GeneratedPluginsPackage.normalizeHostSwiftSource(input);

      expect(output, contains('let before = true'));
      expect(output, contains('let after = true'));
      expect(output, contains('// #Preview { broken( }'));
      expect(output, contains('"#Preview { broken( }"'));
      expect(output, contains('#"#Preview { broken( }"#'));
      expect(output, contains('#Previewable @State'));
      expect(output, isNot(contains('@available(iOS 17.0, *)')));
      expect(output, isNot(contains('#Preview(\n')));
      expect(output, isNot(contains('#Preview { OtherView() }')));
      expect(GeneratedPluginsPackage.normalizeHostSwiftSource(output), output);
    });

    test('preserves LF and CRLF exactly', () {
      for (final newline in ['\n', '\r\n']) {
        final input = [
          'let before = true',
          '@available(iOS 17.0, *)',
          '#Preview("One") {',
          '  View()',
          '}',
          'let after = true',
          '',
        ].join(newline);
        final output = GeneratedPluginsPackage.normalizeHostSwiftSource(input);
        expect(
          '\r\n'.allMatches(output).length,
          '\r\n'.allMatches(input).length,
        );
        expect('\n'.allMatches(output).length, '\n'.allMatches(input).length);
        expect(output, contains('let before = true$newline'));
        expect(output, contains('${newline}let after = true$newline'));
      }
    });

    test('throws on an unbalanced actual preview', () {
      expect(
        () => GeneratedPluginsPackage.normalizeHostSwiftSource(
          '#Preview("Broken") {\n  VStack {\n',
        ),
        throwsA(isA<FlutterBuildError>()),
      );
    });
  });

  group('normalizeHostSwiftTree', () {
    test('normalizes arbitrary checkout paths and skips manifests', () async {
      final root = p.join(tmp.path, 'scratch', 'checkouts', 'generic-package');
      final source = File(p.join(root, 'Sources', 'Feature', 'Widget.swift'))
        ..createSync(recursive: true)
        ..writeAsStringSync('let before = 1\n#Preview { Widget() }\n');
      final manifest = File(p.join(root, 'Package.swift'))
        ..writeAsStringSync('#Preview { Manifest() }\n');
      final versionedManifest = File(p.join(root, 'Package@swift-6.0.swift'))
        ..writeAsStringSync('#Preview { Manifest() }\n');

      await GeneratedPluginsPackage.normalizeHostSwiftTree(
        p.join(tmp.path, 'scratch', 'checkouts'),
      );

      expect(source.readAsStringSync(), contains('let before = 1'));
      expect(source.readAsStringSync(), isNot(contains('#Preview')));
      expect(manifest.readAsStringSync(), contains('#Preview'));
      expect(versionedManifest.readAsStringSync(), contains('#Preview'));
    });

    test('does not partially write when any source is malformed', () async {
      final root = p.join(tmp.path, 'tree');
      final valid = File(p.join(root, 'A', 'Valid.swift'))
        ..createSync(recursive: true)
        ..writeAsStringSync('#Preview { Valid() }\n');
      final malformed = File(p.join(root, 'B', 'Malformed.swift'))
        ..createSync(recursive: true)
        ..writeAsStringSync('#Preview { Broken(\n');
      final validBefore = valid.readAsBytesSync();
      final malformedBefore = malformed.readAsBytesSync();

      await expectLater(
        GeneratedPluginsPackage.normalizeHostSwiftTree(root),
        throwsA(isA<FlutterBuildError>()),
      );
      expect(valid.readAsBytesSync(), validBefore);
      expect(malformed.readAsBytesSync(), malformedBefore);
    });
  });

  group('parseUrlPackageDeps / gitRefFromVersionArgs', () {
    test('parses exact and from requirements', () {
      const manifest = '''
dependencies: [
    .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "8.58.1"),
    .package(name: "Sentry", url: "https://github.com/getsentry/sentry-cocoa.git", from: "8.0.0"),
    .package(url: "https://example.com/pkg", .upToNextMajor(from: "1.2.3")),
]
''';
      final deps = GeneratedPluginsPackage.parseUrlPackageDeps(manifest);
      expect(deps, hasLength(3));
      expect(deps[0].url, 'https://github.com/getsentry/sentry-cocoa');
      expect(deps[0].name, isNull);
      expect(
        GeneratedPluginsPackage.gitRefFromVersionArgs(deps[0].versionArgs),
        '8.58.1',
      );
      expect(deps[1].name, 'Sentry');
      expect(
        GeneratedPluginsPackage.gitRefFromVersionArgs(deps[1].versionArgs),
        '8.0.0',
      );
      expect(
        GeneratedPluginsPackage.gitRefFromVersionArgs(deps[2].versionArgs),
        '1.2.3',
      );
    });

    test('vendorPackageDirName strips .git and sanitizes ref', () {
      expect(
        GeneratedPluginsPackage.vendorPackageDirName(
          'https://github.com/getsentry/sentry-cocoa.git',
          '8.58.1',
        ),
        'sentry-cocoa@8.58.1',
      );
    });

    test('balances nested parens in multiline upToNextMajor deps', () {
      const manifest = '''
dependencies: [
        .package(
            url: "https://github.com/appmetrica/appmetrica-sdk-ios",
            .upToNextMajor(from: "6.1.0")
        ),
]
''';
      final deps = GeneratedPluginsPackage.parseUrlPackageDeps(manifest);
      expect(deps, hasLength(1));
      expect(
        deps.single.url,
        'https://github.com/appmetrica/appmetrica-sdk-ios',
      );
      expect(
        GeneratedPluginsPackage.gitRefFromVersionArgs(deps.single.versionArgs),
        '6.1.0',
      );
      expect(deps.single.match, endsWith(')'));
      expect(deps.single.match, isNot(contains('),')));
      // Full call replaced — no leftover closing paren from the original.
      final rewritten = manifest.replaceFirst(
        deps.single.match,
        '.package(path: "/vendor/appmetrica")',
      );
      expect(
        rewritten,
        contains(
          'dependencies: [\n'
          '        .package(path: "/vendor/appmetrica"),\n'
          ']',
        ),
      );
    });
  });

  group('vendorUrlPackagesAsPathDeps', () {
    test('rewrites url deps to path after clone callback', () async {
      final vendorDir = p.join(tmp.path, 'Vendor');
      const manifest = '''
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "plugin_a",
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "8.58.1"),
    ],
    targets: [
        .target(
            name: "plugin_a",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa")
            ]
        )
    ]
)
''';
      final rewritten =
          await GeneratedPluginsPackage.vendorUrlPackagesAsPathDeps(
            manifest,
            vendorDir: vendorDir,
            locateTool: (name) async {
              expect(name, 'git');
              return 'git';
            },
            clonePackage: (git, url, ref, destination) async {
              expect(git, 'git');
              expect(url, 'https://github.com/getsentry/sentry-cocoa');
              expect(ref, '8.58.1');
              await Directory(destination).create(recursive: true);
              await File(p.join(destination, 'Package.swift')).writeAsString('''
#if canImport(Darwin)
import Darwin.C
#elseif canImport(Glibc)
import Glibc
#elseif canImport(MSVCRT)
import MSVCRT
#endif
import PackageDescription
let env = getenv("X")
let package = Package(name: "Sentry", products: [], targets: [])
''');
              await File(
                p.join(destination, 'Package@swift-6.1.swift'),
              ).writeAsString(
                'String(cString: env, encoding: .utf8)\n'
                '#elseif canImport(MSVCRT)\n'
                'import MSVCRT\n',
              );
            },
          );

      expect(rewritten, isNot(contains('url:')));
      expect(
        rewritten,
        contains(
          '.package(name: "sentry-cocoa", '
          'path: "${swiftPath(p.join(vendorDir, 'sentry-cocoa@8.58.1'))}")',
        ),
      );
      expect(
        rewritten,
        contains('.product(name: "Sentry", package: "sentry-cocoa")'),
      );
      final vendored = File(
        p.join(vendorDir, 'sentry-cocoa@8.58.1', 'Package.swift'),
      ).readAsStringSync();
      expect(vendored, contains('import CRT'));
      final vendored61 = File(
        p.join(vendorDir, 'sentry-cocoa@8.58.1', 'Package@swift-6.1.swift'),
      ).readAsStringSync();
      expect(vendored61, contains('String(cString: env)'));
      expect(vendored61, contains('import CRT'));
    });
  });

  group('Windows checkout symlinks', () {
    test(
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

        await GeneratedPluginsPackage.materializeCheckoutSymlinks(
          p.join(tmp.path, 'scratch'),
        );
        await GeneratedPluginsPackage.materializeCheckoutSymlinks(
          p.join(tmp.path, 'scratch'),
        );

        expect(placeholder.readAsStringSync(), 'materialized');
        if (Platform.isWindows) {
          target.writeAsStringSync('updated');
          expect(placeholder.readAsStringSync(), 'updated');
        }
      },
    );
  });

  group('registrantSource', () {
    test('imports and registers only the plugin with a pluginClass', () {
      final pluginA = makePlugin('plugin_a', pluginClass: 'PluginA');
      final pluginB = makePlugin('plugin_b');

      final source = GeneratedPluginsPackage.registrantSource([
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
    });

    test(
      'emits a function with an empty body when no plugin has a pluginClass',
      () {
        final pluginA = makePlugin('plugin_a');

        final source = GeneratedPluginsPackage.registrantSource([pluginA]);

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

        await GeneratedPluginsPackage.writeGeneratedPackages(
          outputDir: outputDir,
          plugins: [plugin],
          flutterXcframework: flutterXcframework,
          copyFlutterXcframework: true,
          vendorRemotePackages: false,
          deploymentTarget: const IosDeploymentTarget('15.6'),
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

    test(
      'copies unchanged Windows-lane sources before preview normalization',
      () async {
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
              ..writeAsStringSync(
                'let runtime = true\r\n#Preview { FeatureView() }\r\n',
              );
        final originalBytes = original.readAsBytesSync();
        final flutterXcframework = p.join(tmp.path, 'Flutter.xcframework');
        Directory(flutterXcframework).createSync(recursive: true);
        final outputDir = p.join(tmp.path, 'out');

        await GeneratedPluginsPackage.writeGeneratedPackages(
          outputDir: outputDir,
          plugins: [plugin],
          flutterXcframework: flutterXcframework,
          copyFlutterXcframework: true,
          vendorRemotePackages: true,
          deploymentTarget: const IosDeploymentTarget('15.6'),
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

        await GeneratedPluginsPackage.normalizeHostSwiftTree(
          p.join(outputDir, 'Packages'),
        );

        expect(staged.readAsStringSync(), contains('let runtime = true'));
        expect(staged.readAsStringSync(), isNot(contains('#Preview')));
        expect(original.readAsBytesSync(), originalBytes);
      },
    );

    test('preserves packageRoot/ios/package ancestry when vendoring', () async {
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

      await GeneratedPluginsPackage.writeGeneratedPackages(
        outputDir: outputDir,
        plugins: [plugin],
        flutterXcframework: flutterXcframework,
        copyFlutterXcframework: true,
        vendorRemotePackages: true,
        deploymentTarget: const IosDeploymentTarget('15.6'),
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

        await GeneratedPluginsPackage.writeGeneratedPackages(
          outputDir: outputDir,
          plugins: [pluginA],
          flutterXcframework: flutterXcframework,
          copyFlutterXcframework: true,
          vendorRemotePackages: false,
          deploymentTarget: const IosDeploymentTarget('15.6'),
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
          await GeneratedPluginsPackage.writeGeneratedPackages(
            outputDir: outputDir,
            plugins: [pluginA],
            flutterXcframework: flutterXcframework,
            copyFlutterXcframework: false,
            vendorRemotePackages: false,
            deploymentTarget: const IosDeploymentTarget('15.6'),
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
          GeneratedPluginsPackage.flutterFrameworkManifest(),
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

      await GeneratedPluginsPackage.writeGeneratedPackages(
        outputDir: outputDir,
        plugins: [plugin],
        flutterXcframework: flutterXcframework,
        copyFlutterXcframework: true,
        vendorRemotePackages: false,
        deploymentTarget: IosDeploymentTarget.fallback,
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
        GeneratedPluginsPackage.flutterFrameworkManifest(),
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

        final toolsetPath = await GeneratedPluginsPackage.writeToolset(
          outputDir: outputDir,
          linkerPath: toolPaths['ld64.lld.exe']!,
          windows: true,
          locateTool: (name) async {
            requested.add(name);
            return toolPaths[name];
          },
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

      final toolsetPath = await GeneratedPluginsPackage.writeToolset(
        outputDir: outputDir,
        linkerPath: toolPaths['llvm-ar']!,
        windows: false,
        locateTool: (name) async {
          requested.add(name);
          return toolPaths[name];
        },
      );

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

      final toolsetPath = await GeneratedPluginsPackage.writeToolset(
        outputDir: p.join(tmp.path, 'sibling output'),
        linkerPath: toolPaths['llvm-ar']!,
        windows: false,
        // Only the unversioned archiver is symlinked onto PATH.
        locateTool: (name) async => name == 'llvm-ar' ? toolPaths[name] : null,
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
        GeneratedPluginsPackage.writeToolset(
          outputDir: p.join(tmp.path, 'empty output'),
          linkerPath: 'ld64.lld',
          windows: false,
          locateTool: (name) async => null,
        ),
        throwsA(isA<FlutterBuildError>()),
      );
    });

    test('keeps the iOS SDK, package flags, and Windows toolset', () {
      final arguments = GeneratedPluginsPackage.swiftBuildArguments(
        pluginsDir: 'plugins',
        scratchPath: 'scratch',
        swiftSdksPath: 'xcross-swift-sdks',
        iosSdk: 'iPhoneOS.sdk',
        flutterFrameworkSlice: 'Flutter.xcframework/ios-arm64',
        toolsetPath: 'toolset.json',
        linkerPath: '/usr/bin/ld64.lld',
        windows: true,
      );

      expect(arguments.take(5), [
        'build',
        '--package-path',
        'plugins',
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
      expect(arguments, contains('-disable-availability-checking'));
      expect(arguments, contains('--disable-automatic-resolution'));
      expect(arguments, isNot(contains('-install_name')));
    });

    test('resolves with package options before the resolve subcommand', () {
      expect(
        GeneratedPluginsPackage.swiftResolveArguments(
          pluginsDir: 'plugins',
          scratchPath: 'scratch',
          swiftSdksPath: 'xcross-swift-sdks',
          toolsetPath: 'toolset.json',
        ),
        [
          'package',
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
      expect(GeneratedPluginsPackage.swiftProcessEnvironment(windows: true), {
        'GIT_CONFIG_COUNT': '1',
        'GIT_CONFIG_KEY_0': 'core.symlinks',
        'GIT_CONFIG_VALUE_0': 'false',
        'EXPERIMENTAL_SPM_BUILDS': '1',
      });
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

      final result = await GeneratedPluginsPackage.discoverAndRewriteDylibs(
        output.path,
      );

      expect(result.libraryPath, p.absolute(aggregate.path));
      expect(result.dylibPaths, {
        p.absolute(aggregate.path),
        p.absolute(dependency.path),
      });
    });
  });

  group('build', () {
    test(
      'returns null and writes nothing when there are no SPM plugins',
      () async {
        final outputDir = p.join(tmp.path, 'out');

        final result = await GeneratedPluginsPackage.build(
          projectRoot: tmp.path,
          plugins: const [],
          flutterXcframework: p.join(tmp.path, 'Flutter.xcframework'),
          outputDir: outputDir,
          deploymentTarget: IosDeploymentTarget.fallback,
        );

        expect(result, isNull);
        expect(Directory(outputDir).existsSync(), isFalse);
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
        final plugin = IosPlugin(name: 'plugin_pod', packageRoot: podspecOnly);
        final outputDir = p.join(tmp.path, 'out');

        final result = await GeneratedPluginsPackage.build(
          projectRoot: tmp.path,
          plugins: [plugin],
          flutterXcframework: p.join(tmp.path, 'Flutter.xcframework'),
          outputDir: outputDir,
          deploymentTarget: IosDeploymentTarget.fallback,
        );

        expect(result, isNull);
        expect(Directory(outputDir).existsSync(), isFalse);
      },
    );
  });
}

Uint8List _emptyMachO() {
  final bytes = Uint8List(32);
  ByteData.sublistView(bytes).setUint32(0, 0xfeedfacf, Endian.little);
  return bytes;
}
