import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/build/swift_runner_builder.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/swift/swift_import.dart';
import 'package:xcross/src/shared/compose/swift/swift_module_index.dart';

/// A module a project imports that the Darwin SDK cannot resolve, with the
/// first non-conditional import that needs it.
@internal
@immutable
final class UnresolvedSwiftImport {
  const UnresolvedSwiftImport(this.module, this.firstUse, {this.publicModule});

  final String module;
  final SwiftImport firstUse;

  /// Set when [module] exists but is an implementation detail of this public
  /// module, which must be imported instead (swiftc rejects the direct import).
  final String? publicModule;
}

/// Builds the module index for [sdkPath] exactly as the build does.
@internal
SwiftModuleIndex swiftModuleIndexFor({
  required HostFileSystemInterface files,
  required String sdkPath,
  required String darwinSdkBundle,
  required String platformSdkName,
  required String baseName,
  Iterable<String> extraModules = const [],
}) => SwiftModuleIndex.scan(
  files: files,
  sdkPath: sdkPath,
  resourceDir: swiftResourceDir(darwinSdkBundle),
  platformSdkName: platformSdkName,
  extraModules: {baseName, ...extraModules},
);

/// Required modules missing from [index], sorted by module name.
@internal
List<UnresolvedSwiftImport> unresolvedSwiftImports(
  KmpProject project,
  SwiftModuleIndex index,
) => [
  for (final module in index.missing(project.requiredSwiftModules))
    UnresolvedSwiftImport(
      module,
      project.swiftImports.firstWhere(
        (i) => !i.conditional && i.module == module,
      ),
      publicModule: index.implementationDetailOf[module],
    ),
];

/// One `  - Module (imported at rel/path:line)` line per unresolved import,
/// with `: implementation detail of X, import X instead` when applicable.
@internal
List<String> formatUnresolvedSwiftImports(
  KmpProject project,
  List<UnresolvedSwiftImport> unresolved,
) => [for (final u in unresolved) _formatUnresolved(project, u)];

String _formatUnresolved(KmpProject project, UnresolvedSwiftImport u) {
  final use = u.firstUse;
  final path = p.isWithin(project.root, use.path)
      ? p.relative(use.path, from: project.root)
      : use.path;
  final hint = u.publicModule == null
      ? ''
      : ': implementation detail of ${u.publicModule}, '
            'import ${u.publicModule} instead';
  return '  - ${u.module} (imported at $path:${use.line})$hint';
}
