import 'package:meta/meta.dart';

/// Resolved toolchain for the App.framework stub build. [linker] is the
/// vetted `ld64.lld` from [DarwinSdk.resolveLd64Lld], passed to clang by path
/// so the driver cannot pick a different one off PATH.
@immutable
final class Toolchain {
  const Toolchain({
    required this.clang,
    required this.iosSdk,
    required this.linker,
  });

  final String clang;
  final String iosSdk;
  final String linker;
}
