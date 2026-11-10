import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// A SwiftPM version requirement of a remote package, as Xcode stores it in
/// `XCRemoteSwiftPackageReference.requirement`.
@internal
@immutable
sealed class SwiftPackageRequirement {
  const SwiftPackageRequirement();

  /// The `.package(url:...)` argument tail after `url: "..."`, e.g.
  /// `exact: "1.2.3"` or `from: "1.0.0"`. Strings are already escaped.
  String get manifestArgument;
}

/// `exactVersion`.
@internal
final class ExactVersionRequirement extends SwiftPackageRequirement {
  const ExactVersionRequirement(this.version);
  final String version;

  @override
  String get manifestArgument => 'exact: ${swiftStringLiteral(version)}';

  @override
  bool operator ==(Object other) =>
      other is ExactVersionRequirement && other.version == version;
  @override
  int get hashCode => Object.hash('exact', version);
  @override
  String toString() => 'exact $version';
}

/// `upToNextMajorVersion`.
@internal
final class UpToNextMajorRequirement extends SwiftPackageRequirement {
  const UpToNextMajorRequirement(this.minimumVersion);
  final String minimumVersion;

  @override
  String get manifestArgument => 'from: ${swiftStringLiteral(minimumVersion)}';

  @override
  bool operator ==(Object other) =>
      other is UpToNextMajorRequirement &&
      other.minimumVersion == minimumVersion;
  @override
  int get hashCode => Object.hash('major', minimumVersion);
  @override
  String toString() => 'from $minimumVersion';
}

/// `upToNextMinorVersion`.
@internal
final class UpToNextMinorRequirement extends SwiftPackageRequirement {
  const UpToNextMinorRequirement(this.minimumVersion);
  final String minimumVersion;

  @override
  String get manifestArgument =>
      '.upToNextMinor(from: ${swiftStringLiteral(minimumVersion)})';

  @override
  bool operator ==(Object other) =>
      other is UpToNextMinorRequirement &&
      other.minimumVersion == minimumVersion;
  @override
  int get hashCode => Object.hash('minor', minimumVersion);
  @override
  String toString() => 'upToNextMinor $minimumVersion';
}

/// `versionRange`: `minimumVersion..<maximumVersion`.
@internal
final class VersionRangeRequirement extends SwiftPackageRequirement {
  const VersionRangeRequirement(this.minimumVersion, this.maximumVersion);
  final String minimumVersion;
  final String maximumVersion;

  @override
  String get manifestArgument =>
      '${swiftStringLiteral(minimumVersion)}..<'
      '${swiftStringLiteral(maximumVersion)}';

  @override
  bool operator ==(Object other) =>
      other is VersionRangeRequirement &&
      other.minimumVersion == minimumVersion &&
      other.maximumVersion == maximumVersion;
  @override
  int get hashCode => Object.hash('range', minimumVersion, maximumVersion);
  @override
  String toString() => '$minimumVersion..<$maximumVersion';
}

/// `branch`.
@internal
final class BranchRequirement extends SwiftPackageRequirement {
  const BranchRequirement(this.branch);
  final String branch;

  @override
  String get manifestArgument => 'branch: ${swiftStringLiteral(branch)}';

  @override
  bool operator ==(Object other) =>
      other is BranchRequirement && other.branch == branch;
  @override
  int get hashCode => Object.hash('branch', branch);
  @override
  String toString() => 'branch $branch';
}

/// `revision`.
@internal
final class RevisionRequirement extends SwiftPackageRequirement {
  const RevisionRequirement(this.revision);
  final String revision;

  @override
  String get manifestArgument => 'revision: ${swiftStringLiteral(revision)}';

  @override
  bool operator ==(Object other) =>
      other is RevisionRequirement && other.revision == revision;
  @override
  int get hashCode => Object.hash('revision', revision);
  @override
  String toString() => 'revision $revision';
}

/// A package the SwiftUI host depends on.
@internal
@immutable
sealed class SwiftPackageReference {
  const SwiftPackageReference();

  /// SwiftPM package identity, used as `package:` in `.product(...)`.
  String get identity;

  /// The full `.package(...)` expression for a manifest.
  String get manifestDeclaration;
}

/// A package fetched from a repository URL.
@internal
final class RemoteSwiftPackage extends SwiftPackageReference {
  const RemoteSwiftPackage({required this.url, required this.requirement});
  final String url;
  final SwiftPackageRequirement requirement;

  @override
  String get identity => swiftPackageIdentityForUrl(url);

  @override
  String get manifestDeclaration =>
      '.package(url: ${swiftStringLiteral(url)}, '
      '${requirement.manifestArgument})';

  @override
  bool operator ==(Object other) =>
      other is RemoteSwiftPackage &&
      other.url == url &&
      other.requirement == requirement;
  @override
  int get hashCode => Object.hash(url, requirement);
  @override
  String toString() => 'RemoteSwiftPackage($url, $requirement)';
}

/// A package on disk; [path] is absolute and normalized.
@internal
final class LocalSwiftPackage extends SwiftPackageReference {
  const LocalSwiftPackage(this.path);
  final String path;

  @override
  String get identity => p.basename(path).toLowerCase();

  @override
  String get manifestDeclaration =>
      '.package(path: ${swiftStringLiteral(path)})';

  @override
  bool operator ==(Object other) =>
      other is LocalSwiftPackage && other.path == path;
  @override
  int get hashCode => path.hashCode;
  @override
  String toString() => 'LocalSwiftPackage($path)';
}

/// The app depends on product [productName] of [package].
@internal
@immutable
final class SwiftPackageProductDependency {
  const SwiftPackageProductDependency({
    required this.productName,
    required this.package,
  });
  final String productName;
  final SwiftPackageReference package;

  @override
  bool operator ==(Object other) =>
      other is SwiftPackageProductDependency &&
      other.productName == productName &&
      other.package == package;
  @override
  int get hashCode => Object.hash(productName, package);
  @override
  String toString() => '$productName (${package.identity})';
}

/// The Swift packages the SwiftUI host's app targets link.
@internal
final class HostSwiftPackages {
  const HostSwiftPackages({
    required this.packages,
    required this.products,
    required this.packageResolvedPath,
    required this.xcodeprojPath,
    this.deploymentTarget,
  });

  static const empty = HostSwiftPackages(
    packages: [],
    products: [],
    packageResolvedPath: null,
    xcodeprojPath: null,
  );

  /// Unique by identity, sorted by identity.
  final List<SwiftPackageReference> packages;

  /// Sorted by package identity then product name.
  final List<SwiftPackageProductDependency> products;

  /// Absolute path of the `Package.resolved` Xcode pinned, or null.
  final String? packageResolvedPath;

  /// Absolute path of the `.xcodeproj` read (the first one when several were
  /// merged), or null when there is none.
  final String? xcodeprojPath;

  /// The highest `IPHONEOS_DEPLOYMENT_TARGET` the app targets declare (Xcode
  /// builds their packages for it), or null when none does.
  final String? deploymentTarget;

  bool get isEmpty => products.isEmpty;
}

/// SwiftPM identity of a URL: last path component without `.git`, lowercase.
@internal
String swiftPackageIdentityForUrl(String url) {
  var last = url.trim();
  while (last.endsWith('/')) {
    last = last.substring(0, last.length - 1);
  }
  final slash = last.lastIndexOf(RegExp('[/:]'));
  if (slash != -1) last = last.substring(slash + 1);
  if (last.toLowerCase().endsWith('.git')) {
    last = last.substring(0, last.length - 4);
  }
  return last.toLowerCase();
}

/// [url] in a form equal for every spelling SwiftPM treats as the same
/// repository: no scheme or user, `host:path` (scp-style SSH) as
/// `host/path`, no trailing `/` or `.git`, lowercase.
@internal
String normalizedSwiftPackageUrl(String url) {
  var value = url.trim().toLowerCase();
  final scheme = value.indexOf('://');
  if (scheme != -1) {
    value = value.substring(scheme + 3);
  } else {
    // `git@host:owner/repo`.
    final colon = value.indexOf(':');
    final slash = value.indexOf('/');
    if (colon != -1 && (slash == -1 || colon < slash)) {
      value = '${value.substring(0, colon)}/${value.substring(colon + 1)}';
    }
  }
  final at = value.indexOf('@');
  final firstSlash = value.indexOf('/');
  if (at != -1 && (firstSlash == -1 || at < firstSlash)) {
    value = value.substring(at + 1);
  }
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  if (value.endsWith('.git')) value = value.substring(0, value.length - 4);
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// A double-quoted Swift string literal for [value].
@internal
String swiftStringLiteral(String value) {
  final buffer = StringBuffer('"');
  for (final rune in value.runes) {
    switch (rune) {
      case 0x5C:
        buffer.write(r'\\');
      case 0x22:
        buffer.write(r'\"');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      case 0x00:
        buffer.write(r'\0');
      default:
        if (rune < 0x20 || rune == 0x7F) {
          buffer.write('\\u{${rune.toRadixString(16)}}');
        } else {
          buffer.writeCharCode(rune);
        }
    }
  }
  buffer.write('"');
  return buffer.toString();
}
