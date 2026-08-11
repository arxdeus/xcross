// Minimal class-file binary builder for tests.
//
// Builds binary `.class` bytes just complete enough for the patcher to parse
// and rewrite.  Layouts follow JVM spec §4.
// ── Primitive encoders ────────────────────────────────────────────────────────

/// Big-endian u2 bytes.
List<int> u2(int v) => [(v >> 8) & 0xFF, v & 0xFF];

/// Big-endian u4 bytes.
List<int> u4(int v) => [
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ];

// ── Constant-pool entry builders ──────────────────────────────────────────────

/// UTF8 entry (tag 1 + u2 length + bytes).  ASCII-safe for test strings.
List<int> cpUtf8(String s) {
  final encoded = s.codeUnits;
  return [1, ...u2(encoded.length), ...encoded];
}

/// Class entry (tag 7 + u2 name_index).
List<int> cpClass(int nameIdx) => [7, ...u2(nameIdx)];

/// NameAndType entry (tag 12 + u2 name_idx + u2 desc_idx).
List<int> cpNameAndType(int nameIdx, int descIdx) =>
    [12, ...u2(nameIdx), ...u2(descIdx)];

/// Methodref entry (tag 10 + u2 class_idx + u2 nat_idx).
List<int> cpMethodref(int classIdx, int natIdx) =>
    [10, ...u2(classIdx), ...u2(natIdx)];

/// Long entry (tag 5 + 8 bytes).  Consumes TWO CP slots per JVM spec §4.4.5.
List<int> cpLong(int high, int low) => [5, ...u4(high), ...u4(low)];

// ── Structural builders ───────────────────────────────────────────────────────

/// Assembles `cp_count u2 + all entry bytes`.
///
/// Correctly accounts for Long/Double double-slot entries.
List<int> cpSection(List<List<int>> entries) {
  // cp_count = slot_count + 1 (slot 0 is unused per spec).
  var slotCount = 1;
  for (final entry in entries) {
    slotCount++;
    if (entry[0] == 5 || entry[0] == 6) slotCount++; // Long or Double
  }
  return [...u2(slotCount), for (final e in entries) ...e];
}

/// Builds a Code attribute **body** (without the outer name_idx/length wrapper):
///
/// ```text
/// max_stack  u2
/// max_locals u2
/// code_length u4
/// code        [code_length]
/// ex_count   u2
/// exceptions [ex_count × 8]
/// attrs_count u2
/// inner attrs [...]
/// ```
List<int> codeBody({
  required int maxStack,
  required int maxLocals,
  required List<int> code,
  int exceptionCount = 0,
  List<(int nameIdx, List<int> body)> innerAttrs = const [],
}) {
  final exBytes = List<int>.filled(exceptionCount * 8, 0);
  final attrBytes = <int>[];
  for (final (ni, b) in innerAttrs) {
    attrBytes.addAll(u2(ni));
    attrBytes.addAll(u4(b.length));
    attrBytes.addAll(b);
  }
  return [
    ...u2(maxStack),
    ...u2(maxLocals),
    ...u4(code.length),
    ...code,
    ...u2(exceptionCount),
    ...exBytes,
    ...u2(innerAttrs.length),
    ...attrBytes,
  ];
}

/// Wraps a Code body with the standard attribute header.
///
/// Assumes CP slot 1 = "Code" (true in every fake class we build).
List<int> codeAttr(List<int> body) => [...u2(1), ...u4(body.length), ...body];

/// Builds a minimal member (field or method) record.
List<int> member({
  required int nameIdx,
  required int descIdx,
  required List<int> codeAttrBytes,
}) =>
    [
      ...u2(0x0001), // ACC_PUBLIC
      ...u2(nameIdx),
      ...u2(descIdx),
      ...u2(1), // attrs_count = 1  (Code only)
      ...codeAttrBytes,
    ];

// ── Class-file header ─────────────────────────────────────────────────────────

/// Standard class-file magic + Java 21 (major 65) version header.
const List<int> classFileHeader = [
  0xCA, 0xFE, 0xBA, 0xBE, // magic
  0x00, 0x00, // minor version 0
  0x00, 0x41, // major version 65 (Java 21)
];
