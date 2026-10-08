import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/mach_o_code_signature.dart';

import 'support/adhoc_macho_fixtures.dart';

void main() {
  Never invalid(String message) => throw StateError(message);

  test('refreshes ad-hoc page hashes after the code is edited', () {
    final bytes = adHocSignedMachO(List.filled(9000, 0x41));
    expect(stalePages(bytes), isEmpty);
    bytes[payloadOffset()] = 0x42;
    bytes[payloadOffset() + 8500] = 0x43;
    expect(stalePages(bytes), [0, 2]);

    expect(
      MachOCodeSignature.refreshAdHocPageHashes(bytes, invalid: invalid),
      isTrue,
    );
    expect(stalePages(bytes), isEmpty);
    expect(
      MachOCodeSignature.refreshAdHocPageHashes(bytes, invalid: invalid),
      isFalse,
    );
  });

  test('leaves certificate-signed and unsigned code untouched', () {
    final signed = adHocSignedMachO([1, 2, 3], flags: 0x10000);
    signed[payloadOffset()] = 9;
    final before = Uint8List.fromList(signed);
    expect(
      MachOCodeSignature.refreshAdHocPageHashes(signed, invalid: invalid),
      isFalse,
    );
    expect(signed, before);
    expect(
      MachOCodeSignature.refreshAdHocPageHashes(
        Uint8List.fromList([0xCA, 0xFE, 0xBA, 0xBE]),
        invalid: invalid,
      ),
      isFalse,
    );
  });

  test('rejects signatures that point outside the file', () {
    final bytes = adHocSignedMachO([1]);
    ByteData.sublistView(bytes).setUint32(44, 0x7fffffff, Endian.little);
    expect(
      () => MachOCodeSignature.refreshAdHocPageHashes(bytes, invalid: invalid),
      throwsStateError,
    );
  });
}
