import 'dart:io';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:path/path.dart' as p;

/// Bundle-relative path in Apple's form: always forward slashes, so seals
/// generated on Windows match the ones a Mac would produce.
String bundleRelativePath(String root, String path) =>
    p.relative(path, from: root).replaceAll(r'\', '/');

Never bundleFail(String root, String path, String reason) => throw AppleError(
  'Bundle "${bundleRelativePath(root, path)}" is invalid: $reason.',
);

/// Canonical key for identity comparisons between two paths. Windows paths
/// are case-insensitive, so they are folded before comparing.
String pathKey(String path) {
  final normalized = p.normalize(p.absolute(path));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool samePath(String left, String right) => pathKey(left) == pathKey(right);

bool isWithinOrEqual(String parent, String child) =>
    samePath(parent, child) || p.isWithin(parent, child);
