import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/jvm_binary.dart';
import 'package:xcross/src/shared/compose/kotlin_constant_pool.dart';

@internal
class KotlinClassAttribute {
  const KotlinClassAttribute({required this.nameIdx, required this.body});

  final int nameIdx;
  final Uint8List body;
}

// ── Member (field or method) ──────────────────────────────────────────────────

@internal
class KotlinClassMember {
  KotlinClassMember({
    required this.accessFlags,
    required this.nameIdx,
    required this.descIdx,
    required List<KotlinClassAttribute> attrs,
  }) : attrs = List<KotlinClassAttribute>.of(attrs);

  final int accessFlags;
  final int nameIdx;
  final int descIdx;

  /// Mutable so that [KotlinClassFile.replaceMethodCode] can swap the Code entry.
  final List<KotlinClassAttribute> attrs;
}

@internal
class KotlinClassFile {
  // ── Factory ────────────────────────────────────────────────────────────────

  factory KotlinClassFile.parse(Uint8List raw) {
    if (readClassU4(raw, 0) != 0xCAFEBABE) {
      throw StateError('ClassFile: bad magic (not 0xCAFEBABE)');
    }
    var off = 4;
    final minor = readClassU2(raw, off);
    off += 2;
    final major = readClassU2(raw, off);
    off += 2;

    final pool = readKotlinConstantPool(raw, off);
    final cp = pool.entries;
    final cpRaw = pool.raw;
    off = pool.nextOffset;

    final accessFlags = readClassU2(raw, off);
    off += 2;
    final thisClass = readClassU2(raw, off);
    off += 2;
    final superClass = readClassU2(raw, off);
    off += 2;
    final ic = readClassU2(raw, off);
    off += 2;
    final interfaces = <int>[];
    for (var j = 0; j < ic; j++) {
      interfaces.add(readClassU2(raw, off));
      off += 2;
    }

    final fc = readClassU2(raw, off);
    off += 2;
    final fields = <KotlinClassMember>[];
    for (var j = 0; j < fc; j++) {
      final res = _parseMember(raw, off);
      fields.add(res.$1);
      off = res.$2;
    }

    final mc = readClassU2(raw, off);
    off += 2;
    final methods = <KotlinClassMember>[];
    for (var j = 0; j < mc; j++) {
      final res = _parseMember(raw, off);
      methods.add(res.$1);
      off = res.$2;
    }

    final cac = readClassU2(raw, off);
    off += 2;
    final classAttrsRes = _parseAttributes(raw, off, cac);

    return KotlinClassFile._(
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
  KotlinClassFile._({
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
  final List<KotlinConstantPoolEntry?> cp;

  /// Raw bytes of the entire constant-pool section (cp_count u2 + entries).
  /// Re-emitted unchanged by [serialize].
  final Uint8List cpRaw;

  final int accessFlags;
  final int thisClass;
  final int superClass;
  final List<int> interfaces;
  final List<KotlinClassMember> fields;

  /// Mutable: [replaceMethodCode] updates entries in-place.
  final List<KotlinClassMember> methods;

  final List<KotlinClassAttribute> classAttrs;

  static (KotlinClassMember, int) _parseMember(Uint8List raw, int startOff) {
    var off = startOff;
    final access = readClassU2(raw, off);
    off += 2;
    final nameIdx = readClassU2(raw, off);
    off += 2;
    final descIdx = readClassU2(raw, off);
    off += 2;
    final ac = readClassU2(raw, off);
    off += 2;
    final res = _parseAttributes(raw, off, ac);
    return (
      KotlinClassMember(
        accessFlags: access,
        nameIdx: nameIdx,
        descIdx: descIdx,
        attrs: res.$1,
      ),
      res.$2,
    );
  }

  static (List<KotlinClassAttribute>, int) _parseAttributes(
    Uint8List raw,
    int startOff,
    int count,
  ) {
    var off = startOff;
    final attrs = <KotlinClassAttribute>[];
    for (var j = 0; j < count; j++) {
      final nameIdx = readClassU2(raw, off);
      off += 2;
      final length = readClassU4(raw, off);
      off += 4;
      final body = Uint8List.sublistView(raw, off, off + length);
      attrs.add(KotlinClassAttribute(nameIdx: nameIdx, body: body));
      off += length;
    }
    return (attrs, off);
  }

  // ── Lookups ────────────────────────────────────────────────────────────────

  String utf8At(int idx) {
    final e = cp[idx];
    if (e == null || e.tag != jvmcpUtf8) return '';
    return e.str ?? '';
  }

  /// Returns the binary/internal name (e.g. `java/lang/Object`) of this
  /// class's direct superclass, or `null` if [superClass] does not point at
  /// a well-formed `CONSTANT_Class` entry.
  String? get superClassName {
    final cls = cp[superClass];
    if (cls == null || cls.tag != jvmcpClass || cls.idx1 == null) return null;
    return utf8At(cls.idx1!);
  }

  /// Returns the 1-based CP index of the Methodref matching [owner]/[name]/[descriptor],
  /// or `null` if not present.
  int? findMethodrefIdx(String owner, String name, String descriptor) {
    for (var idx = 0; idx < cp.length; idx++) {
      final e = cp[idx];
      if (e == null || e.tag != jvmcpMethodref) continue;
      final clsIdx = e.idx1;
      final natIdx = e.idx2;
      if (clsIdx == null || natIdx == null) continue;
      final cls = cp[clsIdx];
      if (cls == null || cls.tag != jvmcpClass || cls.idx1 == null) continue;
      if (utf8At(cls.idx1!) != owner) continue;
      final nat = cp[natIdx];
      if (nat == null || nat.tag != jvmcpNameAndType) continue;
      final nIdx = nat.idx1;
      final dIdx = nat.idx2;
      if (nIdx == null || dIdx == null) continue;
      if (utf8At(nIdx) == name && utf8At(dIdx) == descriptor) return idx;
    }
    return null;
  }

  int? _findUtf8Idx(String value) {
    for (var idx = 0; idx < cp.length; idx++) {
      final e = cp[idx];
      if (e != null && e.tag == jvmcpUtf8 && e.str == value) return idx;
    }
    return null;
  }

  int? findMethod(String name, String descriptor) {
    for (var idx = 0; idx < methods.length; idx++) {
      final m = methods[idx];
      if (utf8At(m.nameIdx) == name && utf8At(m.descIdx) == descriptor) {
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
  void replaceMethodCode(String name, String descriptor, Uint8List newCode) {
    final mIdx = findMethod(name, descriptor);
    if (mIdx == null) {
      throw StateError('ClassFile: method $name$descriptor not found');
    }
    final codeAttrNameIdx = _findUtf8Idx('Code');
    if (codeAttrNameIdx == null) {
      throw StateError("ClassFile: 'Code' UTF8 not in constant pool");
    }
    final method = methods[mIdx];
    final codeAttrIdx = method.attrs.indexWhere(
      (a) => a.nameIdx == codeAttrNameIdx,
    );
    if (codeAttrIdx < 0) {
      throw StateError(
        'ClassFile: method $name$descriptor has no Code attribute',
      );
    }

    final body = method.attrs[codeAttrIdx].body;
    final maxStack = readClassU2(body, 0);
    final maxLocals = readClassU2(body, 2);
    final codeLength = readClassU4(body, 4);

    if (newCode.length > codeLength) {
      throw ArgumentError(
        'ClassFile: new code (${newCode.length}B) exceeds '
        'original Code length ($codeLength B)',
      );
    }

    // Front-pad with NOPs to keep original code_length.
    final padSize = codeLength - newCode.length;
    final padded = Uint8List(codeLength);
    padded.fillRange(0, padSize, 0x00);
    padded.setRange(padSize, codeLength, newCode);

    // Skip original exception table entries.
    var innerOff = 8 + codeLength;
    final exCount = readClassU2(body, innerOff);
    innerOff += 2 + 8 * exCount;

    // Parse inner attributes; drop StackMapTable.
    final innerAttrCount = readClassU2(body, innerOff);
    innerOff += 2;
    final innerRes = _parseAttributes(body, innerOff, innerAttrCount);
    final innerAttrs = innerRes.$1;
    final stackMapIdx = _findUtf8Idx('StackMapTable');
    final keptInner = innerAttrs
        .where((a) => a.nameIdx != stackMapIdx)
        .toList();

    // Rebuild Code attribute body.
    final builder = BytesBuilder(copy: false);
    builder.add(emitClassU2(maxStack));
    builder.add(emitClassU2(maxLocals));
    builder.add(emitClassU4(codeLength));
    builder.add(padded);
    builder.add(emitClassU2(0)); // empty exception table
    builder.add(_emitAttributes(keptInner));

    method.attrs[codeAttrIdx] = KotlinClassAttribute(
      nameIdx: codeAttrNameIdx,
      body: builder.toBytes(),
    );
  }

  // ── Serialization ──────────────────────────────────────────────────────────

  /// Re-serialises the (possibly modified) class file to bytes.
  Uint8List serialize() {
    final builder = BytesBuilder(copy: false);
    builder.add(const [0xCA, 0xFE, 0xBA, 0xBE]);
    builder.add(emitClassU2(minor));
    builder.add(emitClassU2(major));
    builder.add(cpRaw); // constant pool verbatim
    builder.add(emitClassU2(accessFlags));
    builder.add(emitClassU2(thisClass));
    builder.add(emitClassU2(superClass));
    builder.add(emitClassU2(interfaces.length));
    for (final iface in interfaces) {
      builder.add(emitClassU2(iface));
    }
    builder.add(emitClassU2(fields.length));
    for (final f in fields) {
      builder.add(_emitMember(f));
    }
    builder.add(emitClassU2(methods.length));
    for (final m in methods) {
      builder.add(_emitMember(m));
    }
    builder.add(_emitAttributes(classAttrs));
    return builder.toBytes();
  }

  static Uint8List _emitAttributes(List<KotlinClassAttribute> attrs) {
    final builder = BytesBuilder(copy: false);
    builder.add(emitClassU2(attrs.length));
    for (final a in attrs) {
      builder.add(emitClassU2(a.nameIdx));
      builder.add(emitClassU4(a.body.length));
      builder.add(a.body);
    }
    return builder.toBytes();
  }

  static Uint8List _emitMember(KotlinClassMember m) {
    final builder = BytesBuilder(copy: false);
    builder.add(emitClassU2(m.accessFlags));
    builder.add(emitClassU2(m.nameIdx));
    builder.add(emitClassU2(m.descIdx));
    builder.add(_emitAttributes(m.attrs));
    return builder.toBytes();
  }
}
