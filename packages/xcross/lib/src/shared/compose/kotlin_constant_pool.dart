import 'dart:convert';
import 'dart:typed_data';
import 'package:xcross/src/shared/compose/jvm_binary.dart';

const int jvmcpUtf8 = 1;
const int jvmcpInteger = 3;
const int jvmcpFloat = 4;
const int jvmcpLong = 5;
const int jvmcpDouble = 6;
const int jvmcpClass = 7;
const int jvmcpString = 8;
const int jvmcpFieldref = 9;
const int jvmcpMethodref = 10;
const int jvmcpIfMethodref = 11; // JVM CONSTANT_InterfaceMethodref, tag 11
const int jvmcpNameAndType = 12;
const int jvmcpMethodHandle = 15;
const int jvmcpMethodType = 16;
const int jvmcpDynamic = 17;
const int jvmcpInvokeDynamic = 18;
const int jvmcpModule = 19;
const int jvmcpPackage = 20;

class KotlinConstantPoolEntry {
  const KotlinConstantPoolEntry({
    required this.tag,
    this.str,
    this.idx1,
    this.idx2,
    this.rawData,
  });

  final int tag;
  final String? str;
  final int? idx1;
  final int? idx2;
  final Uint8List? rawData;
}

// ── Attribute ─────────────────────────────────────────────────────────────────

final class KotlinConstantPoolData {
  const KotlinConstantPoolData(this.entries, this.raw, this.nextOffset);
  final List<KotlinConstantPoolEntry?> entries;
  final Uint8List raw;
  final int nextOffset;
}

KotlinConstantPoolData readKotlinConstantPool(Uint8List raw, int offset) {
  var off = offset;
  final cpStart = off;
  final cpCount = readClassU2(raw, off);
  off += 2;
  final cp = <KotlinConstantPoolEntry?>[null]; // index 0 is unused
  var i = 1;
  while (i < cpCount) {
    final tag = raw[off];
    switch (tag) {
      case jvmcpUtf8:
        final len = readClassU2(raw, off + 1);
        final strBytes = Uint8List.sublistView(raw, off + 3, off + 3 + len);
        final str = utf8.decode(strBytes, allowMalformed: true);
        cp.add(KotlinConstantPoolEntry(tag: tag, str: str));
        off += 3 + len;
      case jvmcpInteger || jvmcpFloat:
        cp.add(
          KotlinConstantPoolEntry(
            tag: tag,
            rawData: Uint8List.sublistView(raw, off + 1, off + 5),
          ),
        );
        off += 5;
      case jvmcpLong || jvmcpDouble:
        // Long and Double each occupy TWO constant-pool indices (JVM §4.4.5).
        // The extra `i++` here advances past the phantom second slot so that
        // subsequent entries are resolved at the correct 1-based index.
        cp.add(
          KotlinConstantPoolEntry(
            tag: tag,
            rawData: Uint8List.sublistView(raw, off + 1, off + 9),
          ),
        );
        cp.add(null); // second slot — phantom entry for the double-width type
        off += 9;
        i++; // consumes two CP indices
      case jvmcpClass ||
          jvmcpString ||
          jvmcpMethodType ||
          jvmcpModule ||
          jvmcpPackage:
        cp.add(
          KotlinConstantPoolEntry(tag: tag, idx1: readClassU2(raw, off + 1)),
        );
        off += 3;
      case jvmcpFieldref ||
          jvmcpMethodref ||
          jvmcpIfMethodref ||
          jvmcpNameAndType ||
          jvmcpDynamic ||
          jvmcpInvokeDynamic:
        cp.add(
          KotlinConstantPoolEntry(
            tag: tag,
            idx1: readClassU2(raw, off + 1),
            idx2: readClassU2(raw, off + 3),
          ),
        );
        off += 5;
      case jvmcpMethodHandle:
        cp.add(
          KotlinConstantPoolEntry(
            tag: tag,
            idx1: raw[off + 1], // reference_kind (u1)
            idx2: readClassU2(raw, off + 2), // reference_index
          ),
        );
        off += 4;
      default:
        throw StateError('ClassFile: unknown CP tag $tag @ offset $off');
    }
    i++;
  }
  final cpRaw = Uint8List.sublistView(raw, cpStart, off);

  // ── After constant pool ────────────────────────────────────────────────
  return KotlinConstantPoolData(cp, cpRaw, off);
}
