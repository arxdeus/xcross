import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Bundle-relative path in Apple's form: always forward slashes, so seals
/// generated on Windows match the ones a Mac would produce.
@internal
@useResult
String bundleRelativePath(String root, String path) =>
    p.relative(path, from: root).replaceAll(r'\', '/');

@internal
Never bundleFail(String root, String path, String reason) => throw AppleError(
  'Bundle "${bundleRelativePath(root, path)}" is invalid: $reason.',
);

/// Canonical key for identity comparisons between two paths. Windows paths
/// are case-insensitive, so they are folded before comparing.
@internal
@useResult
String pathKey(String path, {required AppleHostServices hostServices}) =>
    hostServices.pathKey(path);

@internal
@useResult
bool samePath(
  String left,
  String right, {
  required AppleHostServices hostServices,
}) =>
    pathKey(left, hostServices: hostServices) ==
    pathKey(right, hostServices: hostServices);

@internal
@useResult
bool isWithinOrEqual(
  String parent,
  String child, {
  required AppleHostServices hostServices,
}) {
  final services = hostServices;
  return samePath(parent, child, hostServices: services) ||
      services.host.paths.context.isWithin(parent, child);
}
