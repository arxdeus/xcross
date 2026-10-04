import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugins.dart';
import 'package:xcross/src/shared/flutter/constants.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmManifest<T extends PlatformHostInterface> {
  SwiftPmManifest({required this.targetPolicy});
  final FlutterTargetBuildPolicy<T> targetPolicy;

  /// `FlutterFramework/Package.swift` contents — wraps `Flutter.xcframework`
  /// as a SwiftPM binary target.
  static String flutterFrameworkManifest() =>
      '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$flutterFrameworkPackageName",
    products: [
        .library(name: "$flutterFrameworkPackageName", targets: ["$flutterFrameworkPackageName"])
    ],
    targets: [
        .binaryTarget(name: "$flutterFrameworkPackageName", path: "Flutter.xcframework")
    ]
)
''';

  /// `Plugins/Package.swift` contents — aggregates every plugin's SPM package
  /// into one dynamic library product depending on [frameworkDir]'s
  /// `FlutterFramework` package plus every entry in [plugins].
  static String pluginsManifest(
    List<IosPlugin> plugins,
    String frameworkDir, {
    required IosDeploymentTarget deploymentTarget,
    Map<String, String>? pluginPackageDirs,
  }) {
    final dependencies = StringBuffer()
      ..writeln(
        '        .package(name: "$flutterFrameworkPackageName", '
        'path: "${SwiftPmFilesystem.swiftPath(frameworkDir)}"),',
      );
    for (final plugin in plugins) {
      final packageDir =
          pluginPackageDirs?[plugin.name] ?? plugin.swiftPackageDir;
      dependencies.writeln(
        '        .package(name: "${plugin.name}", '
        'path: "${SwiftPmFilesystem.swiftPath(packageDir)}"),',
      );
    }

    final targetDependencies = StringBuffer()
      ..writeln(
        '                .product(name: "$flutterFrameworkPackageName", '
        'package: "$flutterFrameworkPackageName"),',
      );
    for (final plugin in plugins) {
      targetDependencies.writeln(
        '                .product(name: "${SwiftPmFilesystem.hyphenate(plugin.name)}", '
        'package: "${plugin.name}"),',
      );
    }

    return '''
// swift-tools-version: 5.9

let package = Package(
    name: "$pluginsProductName",
    platforms: [
        .iOS("${deploymentTarget.version}")
    ],
    products: [
        .library(name: "$pluginsProductName", type: .dynamic, targets: ["$pluginsProductName"])
    ],
    dependencies: [
$dependencies    ],
    targets: [
        .target(
            name: "$pluginsProductName",
            dependencies: [
$targetDependencies            ]
        )
    ]
)
''';
  }

  /// `GeneratedPluginRegistrant.swift` contents — imports and registers each
  /// plugin that has a non-null `pluginClassIos`. Plugins with no class
  /// (facade/pure-Dart/FFI-only packages) remain SwiftPM target dependencies,
  /// but need no module import or registration call.
  String registrantSource(
    List<IosPlugin> plugins, {
    bool verbose = false,
    Map<String, String> stagedPackageDirs = const {},
  }) {
    final imports = StringBuffer();
    final registrations = StringBuffer();
    var pluginCount = 0;
    for (final plugin in plugins) {
      final pluginClass = plugin.pluginClassIos;
      if (pluginClass == null) continue;
      pluginCount++;
      imports.writeln('import ${plugin.name}');
      final registration = StringBuffer();
      if (verbose) {
        registration.writeln('''
    NSLog("[xcross] registering plugin ${plugin.name} ($pluginClass)")
    if let registrar = registry.registrar(forPlugin: "$pluginClass") {
        $pluginClass.register(with: registrar)
        registered += 1
        NSLog("[xcross] registered plugin ${plugin.name} ($pluginClass)")
    } else {
        failures.append("${plugin.name} ($pluginClass): registrar unavailable")
        NSLog("[xcross] failed plugin ${plugin.name} ($pluginClass): registrar unavailable")
    }''');
      } else {
        registration.writeln('''
    if let registrar = registry.registrar(forPlugin: "$pluginClass") {
        $pluginClass.register(with: registrar)
    }''');
      }
      final availableFrom = plugin.pluginClassIosAvailabilityIn(
        policy: targetPolicy,
        stagedPackage: stagedPackageDirs[plugin.name],
      );
      if (availableFrom == null) {
        registrations.write(registration);
      } else {
        registrations.writeln('''
    if #available(iOS $availableFrom, *) {''');
        registrations.write(registration);
        registrations.writeln('    } else {');
        if (verbose) {
          registrations.writeln(
            '''
        failures.append("${plugin.name} ($pluginClass): requires iOS $availableFrom")
        NSLog("[xcross] skipped plugin ${plugin.name} ($pluginClass): requires iOS $availableFrom")''',
          );
        }
        registrations.writeln('    }');
      }
    }

    final diagnosticsStart = verbose
        ? '    var registered = 0\n'
              '    var failures: [String] = []\n'
        : '';
    final diagnosticsEnd = verbose
        ? '    NSLog("[xcross] plugin registration summary: '
              '$pluginCount attempted, \\(registered) registered, '
              '\\(failures.count) failed")\n'
              '    for failure in failures {\n'
              '        NSLog("[xcross] plugin registration failure: '
              '\\(failure)")\n'
              '    }\n'
        : '';

    return '''
//
// Generated file. Do not edit.
//
import Flutter
import UIKit
$imports
@_cdecl("${GeneratedPluginsConstants.registrantSymbol}")
public func xcrossRegisterGeneratedPlugins(_ registry: FlutterPluginRegistry) {
$diagnosticsStart$registrations$diagnosticsEnd}
''';
  }
}
