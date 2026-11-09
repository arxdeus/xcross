import 'package:meta/meta.dart';
import 'package:xcross/src/shared/errors/build_error.dart';

/// A user-facing error from resolving or building Swift packages.
@internal
final class SwiftPmError extends XcrossBuildError {
  SwiftPmError(super.message, {super.isSecurityFailure});
}
