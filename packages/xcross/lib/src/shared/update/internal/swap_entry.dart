import 'package:meta/meta.dart';

/// One file replaced during a swap, and where its predecessor was parked so
/// the whole set can be rolled back as a unit.
@immutable
final class SwapEntry {
  const SwapEntry({required this.target, required this.backup});

  /// The installed path that now holds the new file.
  final String target;

  /// The renamed-aside previous file, or null when [target] is new.
  final String? backup;
}
