final class Arm64AdrpLdr {
  const Arm64AdrpLdr({required this.adrp, required this.ldr});

  final int adrp;
  final int ldr;

  static int? decodeTarget({
    required int adrp,
    required int ldr,
    required int instructionAddress,
    int adrpRegister = 1,
    int ldrRegister = 1,
  }) {
    if ((adrp & 0x9f00001f) != (0x90000000 | adrpRegister) ||
        (ldr & 0xffc003ff) !=
            (0xf9400000 | (adrpRegister << 5) | ldrRegister)) {
      return null;
    }
    final immediate = ((adrp >> 5) & 0x7ffff) << 2 | (adrp >> 29) & 3;
    final pageDelta = _signExtend(immediate, 21);
    return (instructionAddress & ~0xfff) +
        pageDelta * 0x1000 +
        ((ldr >> 10) & 0xfff) * 8;
  }

  static Arm64AdrpLdr? encodeTarget({
    required int targetAddress,
    required int instructionAddress,
    int adrpRegister = 1,
    int ldrRegister = 1,
  }) {
    final pageDelta = (targetAddress & ~0xfff) - (instructionAddress & ~0xfff);
    if (pageDelta % 0x1000 != 0 ||
        pageDelta < -0x100000000 ||
        pageDelta > 0xfffff000 ||
        (targetAddress & 7) != 0) {
      return null;
    }
    final immediate = (pageDelta ~/ 0x1000) & 0x1fffff;
    return Arm64AdrpLdr(
      adrp:
          0x90000000 |
          adrpRegister |
          ((immediate & 3) << 29) |
          (((immediate >> 2) & 0x7ffff) << 5),
      ldr:
          0xf9400000 |
          (adrpRegister << 5) |
          ldrRegister |
          (((targetAddress & 0xfff) ~/ 8) << 10),
    );
  }

  static int _signExtend(int value, int bits) {
    final sign = 1 << (bits - 1);
    return (value ^ sign) - sign;
  }
}
