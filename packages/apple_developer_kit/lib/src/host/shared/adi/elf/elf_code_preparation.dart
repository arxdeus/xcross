import 'dart:ffi';

import 'package:meta/meta.dart';

@internal
abstract interface class ElfCodePreparation {
  void prepare(Pointer<Uint8> code, int length);
}

@internal
final class UnmodifiedElfCodePreparation implements ElfCodePreparation {
  const UnmodifiedElfCodePreparation();

  @override
  void prepare(Pointer<Uint8> code, int length) {}
}
