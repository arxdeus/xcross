import 'package:meta/meta.dart';

/// A page-aligned protection range within an [ElfImage].
@immutable
final class ElfPageRange {
  const ElfPageRange({required this.offset, required this.length});

  final int offset;
  final int length;
}
