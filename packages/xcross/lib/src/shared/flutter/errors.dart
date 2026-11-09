import 'package:meta/meta.dart';
import 'package:xcross/src/shared/errors/build_error.dart';

/// A user-facing error from Flutter iOS packing or hot reload.
@internal
final class FlutterBuildError extends XcrossBuildError {
  FlutterBuildError(super.message, {super.isSecurityFailure});
}
