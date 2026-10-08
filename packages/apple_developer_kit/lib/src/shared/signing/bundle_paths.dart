import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

/// Bundle-relative path in Apple's form: always forward slashes, so seals
/// generated on Windows match the ones a Mac would produce.
@internal
@useResult
String bundleRelativePath(
  String root,
  String path, {
  required HostPathsInterface paths,
}) => paths.context.split(paths.context.relative(path, from: root)).join('/');

@internal
Never bundleFail(
  String root,
  String path,
  String reason, {
  required HostPathsInterface paths,
}) => throw AppleError(
  'Bundle "${bundleRelativePath(root, path, paths: paths)}" is invalid: $reason.',
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
