import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/apple/xcodeproj/pbx_parser.dart';
import 'package:xcross/src/shared/compose/swiftpm/swift_package_model.dart';
import 'package:xcross/src/shared/errors/errors.dart';

const _applicationProductType = 'com.apple.product-type.application';

/// Reads the Swift packages the app targets of the Xcode project(s) directly
/// in [iosAppDir] link.
///
/// * Only `PBXNativeTarget`s with product type `application` count. Test and
///   extension targets are ignored, and so are packages none of the app
///   targets uses.
/// * Several `.xcodeproj` bundles are merged: their products are unioned and
///   the same package identity must resolve to the same reference, otherwise
///   an [XcrossError] is thrown (SwiftPM rejects duplicate identities too).
///   `xcodeprojPath` is then the first project in name order.
/// * A product dependency without `package` (local packages added as a
///   folder reference) is matched against the `.library(name:)` products
///   declared in the `Package.swift` of the project's local packages.
/// * No project or no packages yields [HostSwiftPackages.empty]-like results.
@internal
HostSwiftPackages readHostSwiftPackages({
  required HostFileSystemInterface files,
  required p.Context paths,
  required String iosAppDir,
}) {
  final dir = files.directory(iosAppDir);
  if (!dir.existsSync()) return HostSwiftPackages.empty;
  final entries = dir.listSync(followLinks: false).map((e) => e.path).toList()
    ..sort();
  final projects = [
    for (final path in entries)
      if (paths.extension(path) == '.xcodeproj' &&
          files.file(paths.join(path, 'project.pbxproj')).existsSync())
        path,
  ];
  if (projects.isEmpty) return HostSwiftPackages.empty;

  final byIdentity = <String, SwiftPackageReference>{};
  final products = <SwiftPackageProductDependency>{};
  final deploymentTargets = <String>{};
  for (final project in projects) {
    for (final product in _readProject(
      files,
      paths,
      project,
      deploymentTargets: deploymentTargets,
    )) {
      final identity = product.package.identity;
      final existing = byIdentity[identity];
      if (existing != null && !_samePackage(existing, product.package)) {
        throw XcrossError(
          'Swift package "$identity" is referenced differently by the Xcode '
          'projects in $iosAppDir ($existing vs ${product.package}). '
          'Use the same package reference in every project.',
        );
      }
      final package = existing ?? product.package;
      byIdentity[identity] = package;
      products.add(
        SwiftPackageProductDependency(
          productName: product.productName,
          package: package,
        ),
      );
    }
  }
  if (products.isEmpty) {
    return HostSwiftPackages(
      packages: const [],
      products: const [],
      packageResolvedPath: null,
      xcodeprojPath: projects.first,
    );
  }

  final sortedIds = byIdentity.keys.toList()..sort();
  final sortedProducts = products.toList()
    ..sort((a, b) {
      final byPackage = a.package.identity.compareTo(b.package.identity);
      return byPackage != 0
          ? byPackage
          : a.productName.compareTo(b.productName);
    });
  return HostSwiftPackages(
    packages: [for (final id in sortedIds) byIdentity[id]!],
    products: sortedProducts,
    packageResolvedPath: findPackageResolved(
      files: files,
      paths: paths,
      iosAppDir: iosAppDir,
      xcodeprojPaths: projects,
    ),
    xcodeprojPath: projects.first,
    deploymentTarget: deploymentTargets.isEmpty
        ? null
        : deploymentTargets.reduce(
            (a, b) => compareVersions(a, b) >= 0 ? a : b,
          ),
  );
}

/// Whether two references name the same package for SwiftPM: equal local
/// paths, or remote URLs equal after [normalizedSwiftPackageUrl] with the
/// same requirement.
bool _samePackage(SwiftPackageReference a, SwiftPackageReference b) =>
    switch ((a, b)) {
      (final RemoteSwiftPackage a, final RemoteSwiftPackage b) =>
        normalizedSwiftPackageUrl(a.url) == normalizedSwiftPackageUrl(b.url) &&
            a.requirement == b.requirement,
      _ => a == b,
    };

/// Compares dotted version strings numerically (`16.0` > `15.4`).
@internal
int compareVersions(String a, String b) {
  final left = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final right = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  for (var i = 0; i < left.length || i < right.length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l.compareTo(r);
  }
  return 0;
}

/// The `Package.resolved` Xcode pins versions in. A workspace in
/// [iosAppDir] that references one of [xcodeprojPaths] wins over the
/// project's embedded workspace. Returns null when none exists.
@internal
String? findPackageResolved({
  required HostFileSystemInterface files,
  required p.Context paths,
  required String iosAppDir,
  required List<String> xcodeprojPaths,
}) {
  String resolvedIn(String workspace) =>
      paths.join(workspace, 'xcshareddata', 'swiftpm', 'Package.resolved');

  final dir = files.directory(iosAppDir);
  if (dir.existsSync()) {
    final workspaces =
        dir
            .listSync(followLinks: false)
            .map((e) => e.path)
            .where((path) => paths.extension(path) == '.xcworkspace')
            .toList()
          ..sort();
    final names = {for (final x in xcodeprojPaths) paths.basename(x)};
    for (final workspace in workspaces) {
      final contents = files.file(
        paths.join(workspace, 'contents.xcworkspacedata'),
      );
      if (!contents.existsSync()) continue;
      final text = contents.readAsStringSync();
      if (!names.any(text.contains)) continue;
      final resolved = resolvedIn(workspace);
      if (files.file(resolved).existsSync()) return resolved;
    }
  }
  for (final project in xcodeprojPaths) {
    final resolved = resolvedIn(paths.join(project, 'project.xcworkspace'));
    if (files.file(resolved).existsSync()) return resolved;
  }
  return null;
}

/// Library product names declared in a `Package.swift` manifest.
@internal
Set<String> declaredLibraryProducts(String manifest) {
  final pattern = RegExp(r'\.library\s*\(\s*name\s*:\s*"((?:[^"\\]|\\.)*)"');
  return {for (final m in pattern.allMatches(manifest)) m.group(1)!};
}

List<SwiftPackageProductDependency> _readProject(
  HostFileSystemInterface files,
  p.Context paths,
  String xcodeproj, {
  Set<String>? deploymentTargets,
}) {
  final pbxPath = paths.join(xcodeproj, 'project.pbxproj');
  final Map<String, Object?> archive;
  try {
    archive = PbxParser(files.file(pbxPath).readAsStringSync()).parseArchive();
  } on FormatException catch (e) {
    throw XcrossError('Cannot parse $pbxPath: ${e.message}');
  }
  final objects = _map(archive['objects']);
  Map<String, Object?> object(Object? id) => _map(objects[id]);
  final projectDir = paths.dirname(xcodeproj);

  SwiftPackageReference? referenceFor(String id) {
    final ref = object(id);
    switch (ref['isa']) {
      case 'XCRemoteSwiftPackageReference':
        final url = ref['repositoryURL'];
        if (url is! String || url.isEmpty) {
          throw XcrossError('Swift package $id in $pbxPath has no URL.');
        }
        return RemoteSwiftPackage(
          url: url,
          requirement: _requirement(_map(ref['requirement']), url, pbxPath),
        );
      case 'XCLocalSwiftPackageReference':
        final relative = ref['relativePath'] ?? ref['path'];
        if (relative is! String || relative.isEmpty) {
          throw XcrossError('Local Swift package $id in $pbxPath has no path.');
        }
        return LocalSwiftPackage(
          paths.normalize(paths.absolute(paths.join(projectDir, relative))),
        );
      default:
        return null;
    }
  }

  // Local packages, for product dependencies without `package`.
  final rootProject = object(archive['rootObject']);
  final locals = <LocalSwiftPackage>{
    for (final id in _list(rootProject['packageReferences']))
      if (id is String)
        if (referenceFor(id) case final LocalSwiftPackage local) local,
  };
  // Pre-Xcode-15 style: a local package added as a folder reference. Its
  // path is relative to what its `sourceTree` names: the enclosing group
  // (`<group>`, resolved through the parent groups' paths; a group without
  // a path adds no segment), the project directory (`SOURCE_ROOT`), or
  // nothing (`<absolute>`).
  final parentOf = <String, String>{};
  for (final MapEntry(:key, :value) in objects.entries) {
    final group = _map(value);
    final isa = group['isa'];
    if (isa != 'PBXGroup' && isa != 'PBXVariantGroup') continue;
    for (final child in _list(group['children'])) {
      if (child is String) parentOf[child] = key;
    }
  }
  final resolving = <String>{};
  String? locationOf(String id) {
    if (!resolving.add(id)) return null; // A cycle: malformed project.
    try {
      final ref = object(id);
      final path = ref['path'];
      final relative = path is String ? path : '';
      final tree = ref['sourceTree'] ?? '<group>';
      switch (tree) {
        case '<absolute>':
          return path is String ? path : null;
        case 'SOURCE_ROOT':
          return paths.join(projectDir, relative);
        case '<group>':
          final parent = parentOf[id];
          final base = parent == null ? projectDir : locationOf(parent);
          return base == null ? null : paths.join(base, relative);
        default:
          return null;
      }
    } finally {
      resolving.remove(id);
    }
  }

  for (final MapEntry(key: id, :value) in objects.entries) {
    final ref = _map(value);
    if (ref['isa'] != 'PBXFileReference') continue;
    if (ref['path'] is! String) continue;
    final type = ref['lastKnownFileType'];
    if (type != 'wrapper' && type != 'folder') continue;
    final location = locationOf(id);
    if (location == null) continue;
    final absolute = paths.normalize(paths.absolute(location));
    if (files.file(paths.join(absolute, 'Package.swift')).existsSync()) {
      locals.add(LocalSwiftPackage(absolute));
    }
  }
  Map<LocalSwiftPackage, Set<String>>? localProducts;

  SwiftPackageReference localOwnerOf(String productName) {
    localProducts ??= {
      for (final local in locals)
        local: _readManifestProducts(files, paths, local.path),
    };
    final owners = [
      for (final MapEntry(:key, :value) in localProducts!.entries)
        if (value.contains(productName)) key,
    ]..sort((a, b) => a.path.compareTo(b.path));
    if (owners.length == 1) return owners.single;
    if (owners.isEmpty) {
      throw XcrossError(
        'Swift package product "$productName" in $pbxPath names no package, '
        'and no local package declares it in Package.swift.',
      );
    }
    throw XcrossError(
      'Swift package product "$productName" in $pbxPath names no package, '
      'and several local packages declare it: '
      '${owners.map((o) => o.path).join(', ')}.',
    );
  }

  final result = <SwiftPackageProductDependency>[];
  // Xcode builds an app target's packages for the target's deployment
  // target (the project's when the target sets none).
  String? deploymentTargetOf(Map<String, Object?> owner) {
    String? found;
    for (final id in _list(
      object(owner['buildConfigurationList'])['buildConfigurations'],
    )) {
      final value = _map(
        object(id)['buildSettings'],
      )['IPHONEOS_DEPLOYMENT_TARGET'];
      if (value is String && value.isNotEmpty) {
        if (found == null || compareVersions(value, found) > 0) found = value;
      }
    }
    return found;
  }

  final projectDeploymentTarget = deploymentTargetOf(rootProject);
  for (final targetId in _list(rootProject['targets'])) {
    final target = object(targetId);
    if (target['isa'] != 'PBXNativeTarget' ||
        target['productType'] != _applicationProductType) {
      continue;
    }
    final deploymentTarget =
        deploymentTargetOf(target) ?? projectDeploymentTarget;
    if (deploymentTarget != null) deploymentTargets?.add(deploymentTarget);
    for (final depId in _list(target['packageProductDependencies'])) {
      final dep = object(depId);
      if (dep['isa'] != 'XCSwiftPackageProductDependency') continue;
      final name = dep['productName'];
      if (name is! String || name.isEmpty) continue;
      // Xcode writes plugin products as `plugin:Name`; they are build tools,
      // not linked libraries.
      if (name.startsWith('plugin:')) continue;
      final packageId = dep['package'];
      final package = packageId is String
          ? referenceFor(packageId)
          : localOwnerOf(name);
      if (package == null) {
        throw XcrossError(
          'Swift package product "$name" in $pbxPath references unknown '
          'package $packageId.',
        );
      }
      result.add(
        SwiftPackageProductDependency(productName: name, package: package),
      );
    }
  }
  return result;
}

Set<String> _readManifestProducts(
  HostFileSystemInterface files,
  p.Context paths,
  String packageDir,
) {
  final manifest = files.file(paths.join(packageDir, 'Package.swift'));
  if (!manifest.existsSync()) return const {};
  return declaredLibraryProducts(manifest.readAsStringSync());
}

SwiftPackageRequirement _requirement(
  Map<String, Object?> raw,
  String url,
  String pbxPath,
) {
  String field(String key) {
    final value = raw[key];
    if (value is String && value.isNotEmpty) return value;
    throw XcrossError(
      'Swift package $url in $pbxPath: requirement "${raw['kind']}" has no '
      '$key.',
    );
  }

  return switch (raw['kind']) {
    'exactVersion' => ExactVersionRequirement(field('version')),
    'upToNextMajorVersion' => UpToNextMajorRequirement(field('minimumVersion')),
    'upToNextMinorVersion' => UpToNextMinorRequirement(field('minimumVersion')),
    'versionRange' => VersionRangeRequirement(
      field('minimumVersion'),
      field('maximumVersion'),
    ),
    'branch' => BranchRequirement(field('branch')),
    'revision' => RevisionRequirement(field('revision')),
    final kind => throw XcrossError(
      'Swift package $url in $pbxPath has unsupported requirement kind '
      '"$kind".',
    ),
  };
}

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const {};

List<Object?> _list(Object? value) => value is List<Object?> ? value : const [];
