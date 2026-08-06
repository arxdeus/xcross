import 'package:apple_developer_kit/src/adi/loader/internal/memory_allocator.dart';
import 'package:meta/meta.dart';

/// The reserved image a library's `PT_LOAD` segments are mapped into,
/// plus the page-aligned lowest `p_vaddr` every offset is relative to.
@immutable
final class ElfImage {
  const ElfImage({required this.allocation, required this.baseVaddr});

  final NativeMemoryBlock allocation;
  final int baseVaddr;
}
