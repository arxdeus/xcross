import 'package:meta/meta.dart';

/// Resolved toolchain for the App.framework stub build. [lldToolsetBin] is the
/// directory containing the PATH-resolved `ld64.lld`.
@immutable
final class Toolchain {
  const Toolchain({
    required this.clang,
    required this.iosSdk,
    required this.lldToolsetBin,
  });

  final String clang;
  final String iosSdk;
  final String lldToolsetBin;
}
