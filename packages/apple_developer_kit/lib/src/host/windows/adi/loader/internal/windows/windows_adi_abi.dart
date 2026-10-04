import 'dart:ffi';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/host/shared/adi/elf/elf_code_preparation.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/linux_abi.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/windows_arm64_code_preparation.dart';
import 'package:apple_developer_kit/src/shared/adi/adi_architecture.dart';
import 'package:apple_developer_kit/src/shared/adi/elf/elf_reader.dart';
import 'package:meta/meta.dart';

@internal
final class WindowsAdiAbi {
  const WindowsAdiAbi._(
    this.architecture,
    this.statLayout,
    this.codePreparation,
  );

  factory WindowsAdiAbi.forAbi(Abi abi) => switch (abi) {
    Abi.windowsX64 => const WindowsAdiAbi._(
      AdiArchitecture.x64,
      LinuxX64StatLayout(),
      UnmodifiedElfCodePreparation(),
    ),
    Abi.windowsArm64 => const WindowsAdiAbi._(
      AdiArchitecture.arm64,
      LinuxArm64StatLayout(),
      WindowsArm64CodePreparation(),
    ),
    _ => throw UnsupportedError('Windows ADI does not support host ABI $abi.'),
  };

  final AdiArchitecture architecture;
  final LinuxStatLayout statLayout;
  final ElfCodePreparation codePreparation;

  void validateElf(Uint8List bytes) {
    final elf = ElfReader(bytes)..validate(machine: architecture.elfMachine);
    for (var index = 0; index < elf.ehPhnum; index++) {
      if (elf.phType(index) == 7) {
        throw UnsupportedError(
          'Windows ADI does not support ELF TLS segments.',
        );
      }
    }
  }
}
