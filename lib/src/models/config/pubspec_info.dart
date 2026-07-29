import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/util/errors.dart';
import 'package:yaml/yaml.dart';

/// Relevant fields read from a Flutter project's `pubspec.yaml`.
@immutable
class PubspecInfo {
  const PubspecInfo({required this.name, required this.usesMaterialDesign});

  /// The package/app name (`name:` key).
  final String name;

  /// Whether `flutter: uses-material-design: true` is set (controls bundling of
  /// `MaterialIcons-Regular.otf`).
  final bool usesMaterialDesign;

  /// Sync so it can be used from a constructor initializer list.
  factory PubspecInfo.loadSync(String projectRoot) {
    final file = File(p.join(projectRoot, 'pubspec.yaml'));
    if (!file.existsSync()) {
      throw XcrossError('pubspec.yaml not found in $projectRoot');
    }
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on Object catch (e) {
      // YamlException is a FormatException, not an XcrossError — rethrow so
      // the CLI reports `error: <msg>` instead of dying with a stack trace.
      throw XcrossError('pubspec.yaml: $e');
    }
    if (doc is! YamlMap) {
      throw XcrossError('pubspec.yaml: invalid document');
    }
    final name = doc['name'];
    if (name is! String) {
      throw XcrossError('pubspec.yaml: missing "name"');
    }
    var usesMaterialDesign = false;
    final flutterSection = doc['flutter'];
    if (flutterSection is YamlMap) {
      usesMaterialDesign = flutterSection['uses-material-design'] == true;
    }
    return PubspecInfo(name: name, usesMaterialDesign: usesMaterialDesign);
  }
}
