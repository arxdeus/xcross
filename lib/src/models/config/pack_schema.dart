import 'dart:io';

import 'package:meta/meta.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:yaml/yaml.dart';

/// How the app's bundle identifier is derived.
@immutable
sealed class IdSpecifier {
  const IdSpecifier();

  /// Compute the final bundle id given the resolved product name.
  String formBundleId(String product);
}

/// `orgID: com.example` → bundle id `com.example.<product>`.
@immutable
class OrgIdSpecifier extends IdSpecifier {
  const OrgIdSpecifier(this.orgId);

  /// The organization identifier prefix.
  final String orgId;

  @override
  String formBundleId(String product) => '$orgId.$product';
}

/// `bundleID: com.example.MyApp` → literal bundle id.
@immutable
class BundleIdSpecifier extends IdSpecifier {
  const BundleIdSpecifier(this.bundleId);

  /// The literal bundle identifier.
  final String bundleId;

  @override
  String formBundleId(String product) => bundleId;
}

/// Parsed `xcross.yml` (schema version 1).
@immutable
class PackSchema {
  const PackSchema({required this.idSpecifier, this.infoPath});

  /// How the bundle identifier is derived.
  final IdSpecifier idSpecifier;

  /// Path to a custom `Info.plist`.
  final String? infoPath;

  /// Default used when no `xcross.yml` is present (`com.example` org).
  factory PackSchema.defaultSchema() =>
      const PackSchema(idSpecifier: OrgIdSpecifier('com.example'));

  static Future<PackSchema> fromFile(String path) async {
    final doc = loadYaml(await File(path).readAsString());
    if (doc is! YamlMap) {
      throw XcrossError('xcross.yml: invalid document');
    }
    final version = doc['version'];
    if (version != 1) {
      throw XcrossError('xcross.yml: Unsupported schema version: $version');
    }
    final bundleId = doc['bundleID'] as String?;
    final orgId = doc['orgID'] as String?;
    final IdSpecifier spec;
    if (bundleId != null) {
      spec = BundleIdSpecifier(bundleId);
    } else if (orgId != null) {
      spec = OrgIdSpecifier(orgId);
    } else {
      throw XcrossError('xcross.yml: Must specify either orgID or bundleID');
    }
    return PackSchema(idSpecifier: spec, infoPath: doc['infoPath'] as String?);
  }
}
