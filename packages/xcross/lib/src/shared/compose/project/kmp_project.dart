import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/project/ios_app_config.dart';
import 'package:xcross/src/shared/compose/swift/swift_import.dart';

@internal
enum KmpEntryKind { runnableApp, swiftApp, frameworkOnly }

@internal
final class KmpProject {
  const KmpProject({
    required this.root,
    required this.modulePath,
    required this.moduleName,
    required this.baseName,
    required this.entryKind,
    required this.bundleId,
    required this.appName,
    this.isStaticFramework = false,
    this.entryClass,
    this.entrySelector,
    this.swiftAppDir,
    this.swiftSources = const [],
    this.swiftImports = const [],
    this.iosConfig,
  });

  final String root;
  final String modulePath;
  final String moduleName;
  final String baseName;
  final KmpEntryKind entryKind;

  /// `binaries.framework { isStatic = true }` in the module's build script.
  /// The framework link must pass `-Xstatic-framework`, otherwise Kotlin/Native
  /// produces a dynamic library and the link then requires every ObjC
  /// dependency of the module (Firebase, system libraries) to be resolvable.
  final bool isStaticFramework;
  final String bundleId;
  final String appName;
  final String? entryClass;
  final String? entrySelector;
  final String? swiftAppDir;
  final List<String> swiftSources;

  /// Every `import` in [swiftSources], with its location. Which modules the
  /// Darwin SDK can resolve is decided at build time against the SDK itself,
  /// not against a fixed list.
  final List<SwiftImport> swiftImports;
  final IosAppConfig? iosConfig;

  /// Top-level modules [swiftSources] import outside `#if` blocks.
  Set<String> get requiredSwiftModules => {
    for (final import in swiftImports)
      if (!import.conditional) import.module,
  };

  String get moduleLeaf => moduleName.split(':').last;

  /// This project with only its framework built: no runner is compiled and
  /// no app is assembled, whatever entry point the sources declare.
  KmpProject asFrameworkOnly() => KmpProject(
    root: root,
    modulePath: modulePath,
    moduleName: moduleName,
    baseName: baseName,
    entryKind: KmpEntryKind.frameworkOnly,
    bundleId: bundleId,
    appName: appName,
    isStaticFramework: isStaticFramework,
    iosConfig: iosConfig,
  );
}
