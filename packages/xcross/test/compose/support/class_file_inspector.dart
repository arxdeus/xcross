// Binary class-file inspector for patcher tests.
//
// Intentionally re-implements the class-file walk independently of the
// patcher's private `_ClassFile` so tests are not testing the parser
// through itself.
import 'dart:typed_data';

// ── Primitive readers ─────────────────────────────────────────────────────────

int read16(Uint8List b, int off) => (b[off] << 8) | b[off + 1];
int read32(Uint8List b, int off) =>
    (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

// ── Inspection result ─────────────────────────────────────────────────────────

/// Snapshot of the Code bodies we care about in a patched HostManager class.
class InspectedClass {
  const InspectedClass({
    required this.isEnabledCodeBody,
    required this.isEnabledCodeLength,
    required this.isEnabledExceptionCount,
    required this.isEnabledInnerAttrNames,
    required this.getEnabledCodeBody,
  });

  final Uint8List isEnabledCodeBody;
  final int isEnabledCodeLength;
  final int isEnabledExceptionCount;
  final List<String> isEnabledInnerAttrNames;
  final Uint8List getEnabledCodeBody;
}

// ── Member walker ─────────────────────────────────────────────────────────────

/// Skips a member table (fields or methods) starting at [off] and returns the
/// offset immediately after the last member.
int skipMembers(Uint8List raw, int off) {
  final count = read16(raw, off);
  var o = off + 2;
  for (var i = 0; i < count; i++) {
    o += 6; // access_flags(2) + name_idx(2) + desc_idx(2)
    final ac = read16(raw, o);
    o += 2;
    for (var k = 0; k < ac; k++) {
      o += 2; // attr name_idx
      final len = read32(raw, o);
      o += 4 + len;
    }
  }
  return o;
}

// ── CP walker helper ──────────────────────────────────────────────────────────

/// Walks the constant pool starting at byte offset [off] (past cp_count u2).
///
/// Returns `(nextOffset, utf8Map)` where `utf8Map` maps CP slot index → string.
(int, Map<int, String>) _walkCp(Uint8List raw, int startOff) {
  final cpCount = read16(raw, startOff);
  var o = startOff + 2;

  final utf8Map = <int, String>{};
  var cpIdx = 1;
  while (cpIdx < cpCount) {
    final tag = raw[o];
    switch (tag) {
      case 1: // UTF8
        final len = read16(raw, o + 1);
        utf8Map[cpIdx] = String.fromCharCodes(raw, o + 3, o + 3 + len);
        o += 3 + len;
      case 3 || 4: // Integer, Float
        o += 5;
      case 5 || 6: // Long, Double → two slots per §4.4.5
        o += 9;
        cpIdx++;
      case 7 ||
          8 ||
          16 ||
          19 ||
          20: // Class, String, MethodType, Module, Package
        o += 3;
      case 9 ||
          10 ||
          11 ||
          12 ||
          17 ||
          18: // Fieldref, Methodref, InterfaceMethodref, NameAndType, Dynamic, InvokeDynamic
        o += 5;
      case 15: // MethodHandle
        o += 4;
      default:
        throw StateError('unexpected CP tag $tag at offset $o');
    }
    cpIdx++;
  }
  return (o, utf8Map);
}

// ── Full inspector ────────────────────────────────────────────────────────────

/// Walks the raw bytes of a patched HostManager class and extracts the Code
/// bodies of `isEnabled` and `getEnabled` for assertion.
InspectedClass parseForInspection(Uint8List raw) {
  // Skip magic(4) + minor(2) + major(2)
  var off = 8;

  final (afterCp, utf8Map) = _walkCp(raw, off);
  off = afterCp;

  final nameToIdx = {for (final e in utf8Map.entries) e.value: e.key};
  final codeNameIdx = nameToIdx['Code'];
  final stackMapNameIdx = nameToIdx['StackMapTable'];
  final isEnabledNameIdx = nameToIdx['isEnabled'];
  final getEnabledNameIdx = nameToIdx['getEnabled'];

  off += 6; // access_flags(2) + this_class(2) + super_class(2)

  // Skip interfaces
  final icount = read16(raw, off);
  off += 2 + icount * 2;

  // Skip fields
  off = skipMembers(raw, off);

  // Parse methods
  final methodCount = read16(raw, off);
  off += 2;

  Uint8List? isEnabledBody;
  var isEnabledCodeLen = 0;
  var isEnabledExCount = 0;
  var isEnabledInnerNames = <String>[];
  Uint8List? getEnabledBody;

  for (var j = 0; j < methodCount; j++) {
    final mNameIdx = read16(raw, off + 2); // access(2) then name_idx
    off += 6; // access(2) + name(2) + desc(2)
    final attrCount = read16(raw, off);
    off += 2;

    for (var k = 0; k < attrCount; k++) {
      final attrNameIdx = read16(raw, off);
      off += 2;
      final attrLen = read32(raw, off);
      off += 4;

      if (attrNameIdx == codeNameIdx) {
        final body = Uint8List.sublistView(raw, off, off + attrLen);
        final codeLen = read32(body, 4);
        final exOff = 8 + codeLen;
        final exCnt = read16(body, exOff);
        var innerOff = exOff + 2 + exCnt * 8;
        final innerCount = read16(body, innerOff);
        innerOff += 2;

        final innerNames = <String>[];
        for (var n = 0; n < innerCount; n++) {
          final iNameIdx = read16(body, innerOff);
          innerOff += 2;
          final iLen = read32(body, innerOff);
          innerOff += 4 + iLen;
          innerNames.add(
            (stackMapNameIdx != null && iNameIdx == stackMapNameIdx)
                ? 'StackMapTable'
                : (utf8Map[iNameIdx] ?? '?'),
          );
        }

        if (mNameIdx == isEnabledNameIdx) {
          isEnabledBody = Uint8List.sublistView(body, 8, 8 + codeLen);
          isEnabledCodeLen = codeLen;
          isEnabledExCount = exCnt;
          isEnabledInnerNames = innerNames;
        } else if (mNameIdx == getEnabledNameIdx) {
          getEnabledBody = Uint8List.sublistView(body, 8, 8 + codeLen);
        }
      }
      off += attrLen;
    }
  }

  return InspectedClass(
    isEnabledCodeBody: isEnabledBody!,
    isEnabledCodeLength: isEnabledCodeLen,
    isEnabledExceptionCount: isEnabledExCount,
    isEnabledInnerAttrNames: isEnabledInnerNames,
    getEnabledCodeBody: getEnabledBody!,
  );
}

// ── Single-method last-code-byte helper ───────────────────────────────────────

/// Returns the Code body (max_stack..end of code array) of the first
/// method's Code attribute in [classBytes].
Uint8List lastMethodCodeBody(Uint8List raw) {
  var off = 8; // past magic + version

  final (afterCp, _) = _walkCp(raw, off);
  off = afterCp;

  off += 6; // access_flags + this + super
  final ic = read16(raw, off);
  off += 2 + ic * 2; // interfaces
  off = skipMembers(raw, off); // fields

  off += 2; // methods_count (only need the first method)
  off += 6; // access + name + desc of first method

  final ac = read16(raw, off);
  off += 2;
  for (var k = 0; k < ac; k++) {
    final attrNameIdx = read16(raw, off);
    off += 2;
    final attrLen = read32(raw, off);
    off += 4;
    // CP slot 1 = "Code" in every fake class we build
    if (attrNameIdx == 1) {
      final codeLen = read32(raw, off + 4);
      return Uint8List.sublistView(raw, off + 8, off + 8 + codeLen);
    }
    off += attrLen;
  }
  throw StateError('Code attribute not found');
}

/// Returns the last byte of the first method's code array in [classBytes].
///
/// Used to verify that `return` (0xB1) lands at the end after NOP-padding in
/// the patched ObjCExportKt class.
int findLastCodeByte(Uint8List raw) => lastMethodCodeBody(raw).last;
