import 'dart:ffi';

import 'package:meta/meta.dart';

@internal
enum AdiArchitecture {
  x64('x86_64', 62),
  arm64('arm64-v8a', 183);

  const AdiArchitecture(this.apkAbi, this.elfMachine);

  final String apkAbi;
  final int elfMachine;

  static AdiArchitecture forAbi(Abi abi) =>
      tryForAbi(abi) ??
      (throw UnsupportedError('ADI does not support host ABI $abi.'));

  static AdiArchitecture? tryForAbi(Abi abi) => switch (abi) {
    Abi.linuxX64 || Abi.macosX64 || Abi.windowsX64 => x64,
    Abi.linuxArm64 || Abi.macosArm64 => arm64,
    _ => null,
  };
}
