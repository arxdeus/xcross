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
  const UnresolvedSwiftImport(this.module, this.firstUse);

  final String module;
  final SwiftImport firstUse;
}

/// Builds the module index for [sdkPath] exactly as the build does.
@internal
SwiftModuleIndex swiftModuleIndexFor({
  required HostFileSystemInterface files,
  required String sdkPath,
  required String darwinSdkBundle,
  required String platformSdkName,
  required String baseName,
}) => SwiftModuleIndex.scan(
  files: files,
  sdkPath: sdkPath,
  resourceDir: swiftResourceDir(darwinSdkBundle),
  platformSdkName: platformSdkName,
  extraModules: {baseName},
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
    ),
];

/// One `  - Module (imported at rel/path:line)` line per unresolved import.
@internal
List<String> formatUnresolvedSwiftImports(
  KmpProject project,
  List<UnresolvedSwiftImport> unresolved,
) => [
  for (final u in unresolved)
    '  - ${u.module} (imported at ${p.isWithin(project.root, u.firstUse.path) ? p.relative(u.firstUse.path, from: project.root) : u.firstUse.path}:${u.firstUse.line})',
];
