import 'package:test/test.dart';
import 'package:xcross/src/apple/arm64_instructions.dart';

void main() {
  test('round trips positive and negative ADRP/LDR targets', () {
    for (final (instruction, target) in [
      (0x100001234, 0x100203ff8),
      (0x200001234, 0x1ff803000),
    ]) {
      final encoded = Arm64AdrpLdr.encodeTarget(
        targetAddress: target,
        instructionAddress: instruction,
      );

      expect(encoded, isNotNull);
      expect(
        Arm64AdrpLdr.decodeTarget(
          adrp: encoded!.adrp,
          ldr: encoded.ldr,
          instructionAddress: instruction,
        ),
        target,
      );
    }
  });

  test('rejects wrong instruction forms and unaligned targets', () {
    expect(
      Arm64AdrpLdr.decodeTarget(
        adrp: 0,
        ldr: 0,
        instructionAddress: 0x100000000,
      ),
      isNull,
    );
    expect(
      Arm64AdrpLdr.encodeTarget(
        targetAddress: 0x100000001,
        instructionAddress: 0x100000000,
      ),
      isNull,
    );
  });
}
