import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/memory_allocator_posix.dart';

final class LinuxMemoryAllocator extends PosixMemoryAllocator {
  LinuxMemoryAllocator() : super(anonymousMappingFlag: 0x20);
}
