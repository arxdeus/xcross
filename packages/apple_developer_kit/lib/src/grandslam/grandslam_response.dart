/// The GrandSlam operation error thrown for a non-zero `Status.ec` in a
/// decoded response envelope.
library;

import 'package:apple_developer_kit/src/errors.dart';

/// A GrandSlam operation error: the response's `Status.ec` was non-zero.
/// [code] is kept separate from the message so callers can recognise
/// specific codes (e.g. `-21669`, "incorrect verification code").
final class GrandSlamOperationError extends AppleError {
  const GrandSlamOperationError(this.code, String em)
    : super('GrandSlam error $code: $em');

  final int code;
}
