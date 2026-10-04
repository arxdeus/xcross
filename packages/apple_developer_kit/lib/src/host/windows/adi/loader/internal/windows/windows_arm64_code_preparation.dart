import 'dart:ffi';

import 'package:apple_developer_kit/src/host/shared/adi/elf/elf_code_preparation.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/sysv_abi_bridge.dart';
import 'package:meta/meta.dart';

@internal
final class WindowsArm64CodePreparation implements ElfCodePreparation {
  const WindowsArm64CodePreparation();

  @override
  void prepare(Pointer<Uint8> code, int length) {
    if (code == nullptr ||
        code.address & 3 != 0 ||
        length <= 0 ||
        length & 3 != 0) {
      throw ArgumentError(
        'ARM64 executable code must be nonempty and aligned.',
      );
    }
    if (provisionWindowsArm64PrepareCode(code.cast(), length) < 0) {
      throw StateError('Windows ARM64 Android TLS code preparation failed.');
    }
  }
}
