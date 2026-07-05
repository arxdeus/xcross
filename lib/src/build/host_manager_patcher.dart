// ignore_for_file: avoid_dynamic_calls
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

// ── Public constants ──────────────────────────────────────────────────────────

/// Marker entry written to the JAR after a successful patch (idempotency key).
const String jarMarkerPath = 'META-INF/POC_HOST_MANAGER_PATCHED';

/// JAR-internal path of Kotlin/Native's HostManager class.
const String hostManagerClassEntry =
    'org/jetbrains/kotlin/konan/target/HostManager.class';

/// JAR-internal path of ObjCExportKt class.
const String objcExportClassEntry =
    'org/jetbrains/kotlin/backend/konan/objcexport/ObjCExportKt.class';

// ── JVM opcodes (only those we emit) ─────────────────────────────────────────

const int _nop = 0x00;
const int _iconst1 = 0x04;
const int _aload0 = 0x2a;
const int _invokeVirtual = 0xb6;
const int _ireturn = 0xac;
const int _areturn = 0xb0;
const int _return = 0xb1;

// ── Constant-pool tags ────────────────────────────────────────────────────────

const int _cpUtf8 = 1;
const int _cpInteger = 3;
const int _cpFloat = 4;
const int _cpLong = 5;
const int _cpDouble = 6;
const int _cpClass = 7;
const int _cpString = 8;
const int _cpFieldref = 9;
const int _cpMethodref = 10;
const int _cpIfMethodref = 11; // JVM CONSTANT_InterfaceMethodref, tag 11
const int _cpNameAndType = 12;
const int _cpMethodHandle = 15;
const int _cpMethodType = 16;
const int _cpDynamic = 17;
const int _cpInvokeDynamic = 18;
const int _cpModule = 19;
const int _cpPackage = 20;

// ── Constant-pool entry ───────────────────────────────────────────────────────

/// Internal representation of one constant-pool slot.
///
/// Fields used depends on [tag]:
/// - UTF8 → [str]
/// - Integer/Float/Long/Double → [rawData] (4 or 8 raw bytes, big-endian)
/// - Class/String/MethodType/Module/Package → [idx1] (name/descriptor index)
/// - Fieldref/Methodref/IfMethodref/NameAndType/Dynamic/InvokeDynamic →
///   [idx1] (class/bootstrap-method index) + [idx2] (name-and-type index)
/// - MethodHandle → [idx1] (reference-kind byte) + [idx2] (reference-index)
class _CpEntry {
  const _CpEntry({
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

class _Attribute {
  const _Attribute({required this.nameIdx, required this.body});

  final int nameIdx;
  final Uint8List body;
}

// ── Member (field or method) ──────────────────────────────────────────────────

class _Member {
  _Member({
    required this.accessFlags,
    required this.nameIdx,
    required this.descIdx,
    required List<_Attribute> attrs,
  }) : attrs = List<_Attribute>.of(attrs);

  final int accessFlags;
  final int nameIdx;
  final int descIdx;

  /// Mutable so that [_ClassFile.replaceMethodCode] can swap the Code entry.
  final List<_Attribute> attrs;
}

// ── Big-endian read helpers ───────────────────────────────────────────────────

int _u2(Uint8List buf, int off) => (buf[off] << 8) | buf[off + 1];

int _u4(Uint8List buf, int off) =>
    (buf[off] << 24) |
    (buf[off + 1] << 16) |
    (buf[off + 2] << 8) |
    buf[off + 3];

// ── Big-endian emit helpers ───────────────────────────────────────────────────

Uint8List _emitU2(int v) => Uint8List.fromList([(v >> 8) & 0xFF, v & 0xFF]);

Uint8List _emitU4(int v) => Uint8List.fromList([
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ]);

// ── Class-file parser / serializer ────────────────────────────────────────────

/// Full parser and re-serializer for a JVM `.class` file.
///
/// The constant pool is preserved verbatim ([cpRaw]) so that we never risk
/// altering constant pool entries that cannot be reconstructed byte-for-byte
/// (e.g., modified UTF-8 encoding, float/double bit patterns).
class _ClassFile {
  _ClassFile._({
    required this.minor,
    required this.major,
    required this.cp,
    required this.cpRaw,
    required this.accessFlags,
    required this.thisClass,
    required this.superClass,
    required this.interfaces,
    required this.fields,
    required this.methods,
    required this.classAttrs,
  });

  final int minor;
  final int major;

  /// 1-indexed; slot 0 and the second slot of every Long/Double are `null`.
  final List<_CpEntry?> cp;

  /// Raw bytes of the entire constant-pool section (cp_count u2 + entries).
  /// Re-emitted unchanged by [serialize].
  final Uint8List cpRaw;

  final int accessFlags;
  final int thisClass;
  final int superClass;
  final List<int> interfaces;
  final List<_Member> fields;

  /// Mutable: [replaceMethodCode] updates entries in-place.
  final List<_Member> methods;

  final List<_Attribute> classAttrs;

  // ── Factory ────────────────────────────────────────────────────────────────

  factory _ClassFile.parse(Uint8List raw) {
    if (_u4(raw, 0) != 0xCAFEBABE) {
      throw StateError('ClassFile: bad magic (not 0xCAFEBABE)');
    }
    var off = 4;
    final minor = _u2(raw, off);
    off += 2;
    final major = _u2(raw, off);
    off += 2;

    // ── Constant pool ──────────────────────────────────────────────────────
    final cpStart = off;
    final cpCount = _u2(raw, off);
    off += 2;
    final cp = <_CpEntry?>[null]; // index 0 is unused
    var i = 1;
    while (i < cpCount) {
      final tag = raw[off];
      switch (tag) {
        case _cpUtf8:
          final len = _u2(raw, off + 1);
          final strBytes = Uint8List.sublistView(raw, off + 3, off + 3 + len);
          final str = utf8.decode(strBytes, allowMalformed: true);
          cp.add(_CpEntry(tag: tag, str: str));
          off += 3 + len;
        case _cpInteger || _cpFloat:
          cp.add(_CpEntry(
            tag: tag,
            rawData: Uint8List.sublistView(raw, off + 1, off + 5),
          ));
          off += 5;
        case _cpLong || _cpDouble:
          // Long and Double each occupy TWO constant-pool indices (JVM §4.4.5).
          // The extra `i++` here advances past the phantom second slot so that
          // subsequent entries are resolved at the correct 1-based index.
          cp.add(_CpEntry(
            tag: tag,
            rawData: Uint8List.sublistView(raw, off + 1, off + 9),
          ));
          cp.add(null); // second slot — phantom entry for the double-width type
          off += 9;
          i++; // consumes two CP indices
        case _cpClass || _cpString || _cpMethodType || _cpModule || _cpPackage:
          cp.add(_CpEntry(tag: tag, idx1: _u2(raw, off + 1)));
          off += 3;
        case _cpFieldref ||
              _cpMethodref ||
              _cpIfMethodref ||
              _cpNameAndType ||
              _cpDynamic ||
              _cpInvokeDynamic:
          cp.add(_CpEntry(
            tag: tag,
            idx1: _u2(raw, off + 1),
            idx2: _u2(raw, off + 3),
          ));
          off += 5;
        case _cpMethodHandle:
          cp.add(_CpEntry(
            tag: tag,
            idx1: raw[off + 1], // reference_kind (u1)
            idx2: _u2(raw, off + 2), // reference_index
          ));
          off += 4;
        default:
          throw StateError('ClassFile: unknown CP tag $tag @ offset $off');
      }
      i++;
    }
    final cpRaw = Uint8List.sublistView(raw, cpStart, off);

    // ── After constant pool ────────────────────────────────────────────────
    final accessFlags = _u2(raw, off);
    off += 2;
    final thisClass = _u2(raw, off);
    off += 2;
    final superClass = _u2(raw, off);
    off += 2;
    final ic = _u2(raw, off);
    off += 2;
    final interfaces = <int>[];
    for (var j = 0; j < ic; j++) {
      interfaces.add(_u2(raw, off));
      off += 2;
    }

    final fc = _u2(raw, off);
    off += 2;
    final fields = <_Member>[];
    for (var j = 0; j < fc; j++) {
      final res = _parseMember(raw, off);
      fields.add(res.$1);
      off = res.$2;
    }

    final mc = _u2(raw, off);
    off += 2;
    final methods = <_Member>[];
    for (var j = 0; j < mc; j++) {
      final res = _parseMember(raw, off);
      methods.add(res.$1);
      off = res.$2;
    }

    final cac = _u2(raw, off);
    off += 2;
    final classAttrsRes = _parseAttributes(raw, off, cac);

    return _ClassFile._(
      minor: minor,
      major: major,
      cp: cp,
      cpRaw: cpRaw,
      accessFlags: accessFlags,
      thisClass: thisClass,
      superClass: superClass,
      interfaces: interfaces,
      fields: fields,
      methods: methods,
      classAttrs: classAttrsRes.$1,
    );
  }

  static (_Member, int) _parseMember(Uint8List raw, int startOff) {
    var off = startOff;
    final access = _u2(raw, off);
    off += 2;
    final nameIdx = _u2(raw, off);
    off += 2;
    final descIdx = _u2(raw, off);
    off += 2;
    final ac = _u2(raw, off);
    off += 2;
    final res = _parseAttributes(raw, off, ac);
    return (
      _Member(
        accessFlags: access,
        nameIdx: nameIdx,
        descIdx: descIdx,
        attrs: res.$1,
      ),
      res.$2,
    );
  }

  static (List<_Attribute>, int) _parseAttributes(
    Uint8List raw,
    int startOff,
    int count,
  ) {
    var off = startOff;
    final attrs = <_Attribute>[];
    for (var j = 0; j < count; j++) {
      final nameIdx = _u2(raw, off);
      off += 2;
      final length = _u4(raw, off);
      off += 4;
      final body = Uint8List.sublistView(raw, off, off + length);
      attrs.add(_Attribute(nameIdx: nameIdx, body: body));
      off += length;
    }
    return (attrs, off);
  }

  // ── Lookups ────────────────────────────────────────────────────────────────

  String _utf8(int idx) {
    final e = cp[idx];
    if (e == null || e.tag != _cpUtf8) return '';
    return e.str ?? '';
  }

  /// Returns the 1-based CP index of the Methodref matching [owner]/[name]/[descriptor],
  /// or `null` if not present.
  int? findMethodrefIdx(String owner, String name, String descriptor) {
    for (var idx = 0; idx < cp.length; idx++) {
      final e = cp[idx];
      if (e == null || e.tag != _cpMethodref) continue;
      final clsIdx = e.idx1;
      final natIdx = e.idx2;
      if (clsIdx == null || natIdx == null) continue;
      final cls = cp[clsIdx];
      if (cls == null || cls.tag != _cpClass || cls.idx1 == null) continue;
      if (_utf8(cls.idx1!) != owner) continue;
      final nat = cp[natIdx];
      if (nat == null || nat.tag != _cpNameAndType) continue;
      final nIdx = nat.idx1;
      final dIdx = nat.idx2;
      if (nIdx == null || dIdx == null) continue;
      if (_utf8(nIdx) == name && _utf8(dIdx) == descriptor) return idx;
    }
    return null;
  }

  int? _findUtf8Idx(String value) {
    for (var idx = 0; idx < cp.length; idx++) {
      final e = cp[idx];
      if (e != null && e.tag == _cpUtf8 && e.str == value) return idx;
    }
    return null;
  }

  int? _findMethod(String name, String descriptor) {
    for (var idx = 0; idx < methods.length; idx++) {
      final m = methods[idx];
      if (_utf8(m.nameIdx) == name && _utf8(m.descIdx) == descriptor) {
        return idx;
      }
    }
    return null;
  }

  // ── Bytecode replacement ───────────────────────────────────────────────────

  /// Rewrites the Code attribute of method [name][descriptor] so that:
  ///
  /// - The bytecode is replaced with [newCode], front-padded with NOPs to
  ///   preserve the original `code_length` (required because class consumers
  ///   may hold stale byte-offset references).
  /// - The exception table is cleared.
  /// - The `StackMapTable` inner attribute is dropped; all other inner
  ///   attributes (e.g. `LineNumberTable`) are kept.
  void replaceMethodCode(
    String name,
    String descriptor,
    Uint8List newCode,
  ) {
    final mIdx = _findMethod(name, descriptor);
    if (mIdx == null) {
      throw StateError('ClassFile: method $name$descriptor not found');
    }
    final codeAttrNameIdx = _findUtf8Idx('Code');
    if (codeAttrNameIdx == null) {
      throw StateError("ClassFile: 'Code' UTF8 not in constant pool");
    }
    final method = methods[mIdx];
    final codeAttrIdx =
        method.attrs.indexWhere((a) => a.nameIdx == codeAttrNameIdx);
    if (codeAttrIdx < 0) {
      throw StateError(
        'ClassFile: method $name$descriptor has no Code attribute',
      );
    }

    final body = method.attrs[codeAttrIdx].body;
    final maxStack = _u2(body, 0);
    final maxLocals = _u2(body, 2);
    final codeLength = _u4(body, 4);

    if (newCode.length > codeLength) {
      throw ArgumentError(
        'ClassFile: new code (${newCode.length}B) exceeds '
        'original Code length ($codeLength B)',
      );
    }

    // Front-pad with NOPs to keep original code_length.
    final padSize = codeLength - newCode.length;
    final padded = Uint8List(codeLength);
    padded.fillRange(0, padSize, _nop);
    padded.setRange(padSize, codeLength, newCode);

    // Skip original exception table entries.
    var innerOff = 8 + codeLength;
    final exCount = _u2(body, innerOff);
    innerOff += 2 + 8 * exCount;

    // Parse inner attributes; drop StackMapTable.
    final innerAttrCount = _u2(body, innerOff);
    innerOff += 2;
    final innerRes = _parseAttributes(body, innerOff, innerAttrCount);
    final innerAttrs = innerRes.$1;
    final stackMapIdx = _findUtf8Idx('StackMapTable');
    final keptInner =
        innerAttrs.where((a) => a.nameIdx != stackMapIdx).toList();

    // Rebuild Code attribute body.
    final builder = BytesBuilder(copy: false);
    builder.add(_emitU2(maxStack));
    builder.add(_emitU2(maxLocals));
    builder.add(_emitU4(codeLength));
    builder.add(padded);
    builder.add(_emitU2(0)); // empty exception table
    builder.add(_emitAttributes(keptInner));

    method.attrs[codeAttrIdx] = _Attribute(
      nameIdx: codeAttrNameIdx,
      body: builder.toBytes(),
    );
  }

  // ── Serialization ──────────────────────────────────────────────────────────

  /// Re-serialises the (possibly modified) class file to bytes.
  Uint8List serialize() {
    final builder = BytesBuilder(copy: false);
    builder.add(const [0xCA, 0xFE, 0xBA, 0xBE]);
    builder.add(_emitU2(minor));
    builder.add(_emitU2(major));
    builder.add(cpRaw); // constant pool verbatim
    builder.add(_emitU2(accessFlags));
    builder.add(_emitU2(thisClass));
    builder.add(_emitU2(superClass));
    builder.add(_emitU2(interfaces.length));
    for (final iface in interfaces) {
      builder.add(_emitU2(iface));
    }
    builder.add(_emitU2(fields.length));
    for (final f in fields) {
      builder.add(_emitMember(f));
    }
    builder.add(_emitU2(methods.length));
    for (final m in methods) {
      builder.add(_emitMember(m));
    }
    builder.add(_emitAttributes(classAttrs));
    return builder.toBytes();
  }

  static Uint8List _emitAttributes(List<_Attribute> attrs) {
    final builder = BytesBuilder(copy: false);
    builder.add(_emitU2(attrs.length));
    for (final a in attrs) {
      builder.add(_emitU2(a.nameIdx));
      builder.add(_emitU4(a.body.length));
      builder.add(a.body);
    }
    return builder.toBytes();
  }

  static Uint8List _emitMember(_Member m) {
    final builder = BytesBuilder(copy: false);
    builder.add(_emitU2(m.accessFlags));
    builder.add(_emitU2(m.nameIdx));
    builder.add(_emitU2(m.descIdx));
    builder.add(_emitAttributes(m.attrs));
    return builder.toBytes();
  }
}

// ── Class-level patch functions ───────────────────────────────────────────────

/// Patches raw [hostManagerClassEntry] bytes.
///
/// Rewrites:
/// - `isEnabled(KonanTarget)Z` → `iconst_1; ireturn`
/// - `getEnabled()Ljava/util/List;` →
///     `aload_0; invokevirtual getTargetValues; areturn`
///
/// Throws [StateError] if the required Methodref is absent.
Uint8List patchHostManagerClassBytes(Uint8List classBytes) {
  final cf = _ClassFile.parse(classBytes);
  final gtvIdx = cf.findMethodrefIdx(
    'org/jetbrains/kotlin/konan/target/HostManager',
    'getTargetValues',
    '()Ljava/util/List;',
  );
  if (gtvIdx == null) {
    throw StateError(
      'HostManagerPatcher: getTargetValues Methodref not in constant pool',
    );
  }
  cf.replaceMethodCode(
    'isEnabled',
    '(Lorg/jetbrains/kotlin/konan/target/KonanTarget;)Z',
    Uint8List.fromList([_iconst1, _ireturn]),
  );
  cf.replaceMethodCode(
    'getEnabled',
    '()Ljava/util/List;',
    Uint8List.fromList([
      _aload0,
      _invokeVirtual,
      (gtvIdx >> 8) & 0xFF,
      gtvIdx & 0xFF,
      _areturn,
    ]),
  );
  return cf.serialize();
}

/// Patches raw [objcExportClassEntry] bytes by replacing every method whose
/// name contains `generateWorkaroundForSwiftSR10177` and whose descriptor
/// ends with `)V` with a single `return` instruction.
///
/// Returns `null` when no matching method is found (non-fatal: the class may
/// not be present in older Kotlin/Native distributions).
Uint8List? patchObjCExportClassBytes(Uint8List classBytes) {
  final cf = _ClassFile.parse(classBytes);
  var patched = false;
  for (final m in cf.methods) {
    final name = cf._utf8(m.nameIdx);
    if (!name.contains('generateWorkaroundForSwiftSR10177')) continue;
    final descriptor = cf._utf8(m.descIdx);
    if (!descriptor.endsWith(')V')) {
      // Non-void variant — unexpected; leave untouched.
      continue;
    }
    cf.replaceMethodCode(
      name,
      descriptor,
      Uint8List.fromList([_return]),
    );
    patched = true;
  }
  return patched ? cf.serialize() : null;
}

// ── Public JAR-level entry point ──────────────────────────────────────────────

/// Patches [hostManagerClassEntry] (and optionally [objcExportClassEntry])
/// inside [jarPath] in place so a `linux_x64` host enables all Apple targets.
///
/// Idempotent: if [jarMarkerPath] is already present the function returns
/// `false` without touching the JAR.  Also returns `false` when neither
/// patchable class is found in the JAR.
///
/// Returns `true` after a successful patch and writes [jarMarkerPath] into
/// the JAR.
bool patchKotlinNativeJar(String jarPath) {
  final jarExists = File(jarPath).existsSync();
  if (!jarExists) {
    return false;
  }

  final tmpPath = '$jarPath.xcross-tmp';
  final input = InputFileStream(jarPath);
  try {
    final archive = ZipDecoder().decodeStream(input);

    // Check idempotency marker.
    if (archive.files.any((f) => f.name == jarMarkerPath)) {
      return false;
    }

    final hasHm = archive.files.any((f) => f.name == hostManagerClassEntry);
    final hasObjC = archive.files.any((f) => f.name == objcExportClassEntry);
    if (!hasHm && !hasObjC) {
      return false;
    }

    // Rebuild the archive with patched entries, streaming to a temp file.
    final output = OutputFileStream(tmpPath);
    final encoder = ZipEncoder();
    encoder.startEncode(output);
    var didPatch = false;

    try {
      for (final entry in archive.files) {
        final name = entry.name;
        final entryBytes = entry.content;

        if (name == hostManagerClassEntry) {
          final patched = patchHostManagerClassBytes(entryBytes);
          encoder.add(ArchiveFile(name, patched.length, patched));
          didPatch = true;
        } else if (name == objcExportClassEntry) {
          final patched = patchObjCExportClassBytes(entryBytes);
          if (patched != null) {
            encoder.add(ArchiveFile(name, patched.length, patched));
            didPatch = true;
          } else {
            encoder.add(ArchiveFile(name, entryBytes.length, entryBytes));
          }
        } else {
          encoder.add(ArchiveFile(name, entryBytes.length, entryBytes));
        }
      }

      if (!didPatch) {
        encoder.endEncode();
        output.closeSync();
        input.closeSync();
        final tmp = File(tmpPath);
        final tmpExists = tmp.existsSync();
        if (tmpExists) tmp.deleteSync();
        return false;
      }

      // Write idempotency marker.
      final markerBytes = utf8.encode('patched\n');
      encoder.add(ArchiveFile(jarMarkerPath, markerBytes.length, markerBytes));
      encoder.endEncode();
    } catch (_) {
      try {
        output.closeSync();
      } catch (_) {}
      final tmp = File(tmpPath);
      final tmpExists = tmp.existsSync();
      if (tmpExists) tmp.deleteSync();
      rethrow;
    }

    output.closeSync();
    input.closeSync();

    // Atomic replace.
    File(tmpPath).renameSync(jarPath);
    return true;
  } catch (_) {
    try {
      input.closeSync();
    } catch (_) {}
    final tmp = File(tmpPath);
    final tmpExists = tmp.existsSync();
    if (tmpExists) tmp.deleteSync();
    rethrow;
  }
}
