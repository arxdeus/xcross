import 'package:xcross/src/shared/compose/project/ios_app_config.dart';

enum KmpEntryKind { runnableApp, swiftApp, frameworkOnly }

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
    this.swiftImports = const {},
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
  final Set<String> swiftImports;
  final IosAppConfig? iosConfig;

  String get moduleLeaf => moduleName.split(':').last;
}
