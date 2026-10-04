import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/memory_allocator_posix.dart';

final class MacOSMemoryAllocator extends PosixMemoryAllocator {
  MacOSMemoryAllocator() : super(anonymousMappingFlag: 0x1000);
}
