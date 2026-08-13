// Synthetic `.class` files and JAR builder used by patcher tests.
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'class_file_builder.dart';

// ── Synthetic HostManager class ───────────────────────────────────────────────
//
// Constant-pool layout (1-indexed):
//   1  UTF8 "Code"
//   2  UTF8 "StackMapTable"
//   3  UTF8 "org/jetbrains/kotlin/konan/target/HostManager"
//   4  Class(3)          ← HostManager
//   5  UTF8 "java/lang/Object"
//   6  Class(5)          ← Object (super)
//   7  UTF8 "getTargetValues"
//   8  UTF8 "()Ljava/util/List;"
//   9  NameAndType(7,8)  ← getTargetValues descriptor
//  10  Methodref(4,9)    ← HostManager.getTargetValues  ← key for patcher
//  11  UTF8 "isEnabled"
//  12  UTF8 "(Lorg/jetbrains/kotlin/konan/target/KonanTarget;)Z"
//  13  UTF8 "getEnabled"
//  14  Long(0,42)        ← occupies slots 14 AND 15 (double-slot test)
//  [15 = null, second slot of Long]
//  16  UTF8 "LineNumberTable"

Uint8List buildFakeHostManagerClass() =>
    _buildFakeHostManagerClass(cpLong(0, 42));

Uint8List buildFakeHostManagerClassWithDouble() =>
    _buildFakeHostManagerClass(cpDouble(0x400921FB, 0x54442D18));

Uint8List _buildFakeHostManagerClass(List<int> doubleSlotEntry) {
  final cpEntries = [
    cpUtf8('Code'), // 1
    cpUtf8('StackMapTable'), // 2
    cpUtf8('org/jetbrains/kotlin/konan/target/HostManager'), // 3
    cpClass(3), // 4
    cpUtf8('java/lang/Object'), // 5
    cpClass(5), // 6
    cpUtf8('getTargetValues'), // 7
    cpUtf8('()Ljava/util/List;'), // 8
    cpNameAndType(7, 8), // 9
    cpMethodref(4, 9), // 10
    cpUtf8('isEnabled'), // 11
    cpUtf8('(Lorg/jetbrains/kotlin/konan/target/KonanTarget;)Z'), // 12
    cpUtf8('getEnabled'), // 13
    doubleSlotEntry, // 14  (Long/Double → takes slots 14+15)
    cpUtf8('LineNumberTable'), // 16
  ];

  // isEnabled Code:
  //   code_length=10, 10×NOP
  //   1 dummy exception entry (8 bytes) → tests that patcher clears it
  //   inner attr: StackMapTable (name_idx=2) → tests that patcher strips it
  final isEnabledBody = codeBody(
    maxStack: 1,
    maxLocals: 2,
    code: List<int>.filled(10, 0),
    exceptionCount: 1,
    innerAttrs: [
      (2, [0x00, 0x00, 0x00]),
    ],
  );

  // getEnabled Code: plain 10×NOP, no exceptions, no inner attrs.
  final getEnabledBody = codeBody(
    maxStack: 1,
    maxLocals: 1,
    code: List<int>.filled(10, 0),
  );

  return Uint8List.fromList([
    ...classFileHeader,
    ...cpSection(cpEntries),
    ...u2(0x0021), // ACC_PUBLIC | ACC_SUPER
    ...u2(4), // this_class  = HostManager (CP#4)
    ...u2(6), // super_class = Object      (CP#6)
    ...u2(0), // interfaces_count = 0
    ...u2(0), // fields_count = 0
    ...u2(2), // methods_count = 2
    ...member(nameIdx: 11, descIdx: 12, codeAttrBytes: codeAttr(isEnabledBody)),
    ...member(nameIdx: 13, descIdx: 8, codeAttrBytes: codeAttr(getEnabledBody)),
    ...u2(0), // class attributes_count = 0
  ]);
}

// ── Synthetic ObjCExportKt class ──────────────────────────────────────────────
//
// Constant-pool layout (1-indexed):
//   1  UTF8 "Code"
//   2  UTF8 "StackMapTable"
//   3  UTF8 "ObjCExportKt"
//   4  Class(3)
//   5  UTF8 "java/lang/Object"
//   6  Class(5)
//   7  UTF8 "generateWorkaroundForSwiftSR10177"
//   8  UTF8 "(LObjCExportedInterface;)V"

Uint8List buildFakeObjCExportClass() {
  final cpEntries = [
    cpUtf8('Code'), // 1
    cpUtf8('StackMapTable'), // 2
    cpUtf8('ObjCExportKt'), // 3
    cpClass(3), // 4
    cpUtf8('java/lang/Object'), // 5
    cpClass(5), // 6
    cpUtf8('generateWorkaroundForSwiftSR10177'), // 7
    cpUtf8('(LObjCExportedInterface;)V'), // 8
  ];

  final methodBody = codeBody(
    maxStack: 1,
    maxLocals: 1,
    code: List<int>.filled(5, 0),
  );

  return Uint8List.fromList([
    ...classFileHeader,
    ...cpSection(cpEntries),
    ...u2(0x0021), // ACC_PUBLIC | ACC_SUPER
    ...u2(4), // this  = ObjCExportKt
    ...u2(6), // super = Object
    ...u2(0), // interfaces
    ...u2(0), // fields
    ...u2(1), // 1 method
    ...member(nameIdx: 7, descIdx: 8, codeAttrBytes: codeAttr(methodBody)),
    ...u2(0), // class attrs
  ]);
}

// ── Synthetic AppleConfigurablesImpl class ────────────────────────────────────
//
// Mirrors the real `getDependencies()` override's constant-pool shape closely
// enough for `findMethodrefIdx` to resolve `CollectionsKt.emptyList()Ljava/util/List;`.
//
// Constant-pool layout (1-indexed):
//   1  UTF8 "Code"
//   2  UTF8 "org/jetbrains/kotlin/konan/target/AppleConfigurablesImpl"
//   3  Class(2)
//   4  UTF8 "java/lang/Object"
//   5  Class(4)
//   6  UTF8 "getDependencies"
//   7  UTF8 "()Ljava/util/List;"
//   8  UTF8 "kotlin/collections/CollectionsKt"
//   9  Class(8)
//  10  UTF8 "emptyList"
//  11  NameAndType(10,7)
//  12  Methodref(9,11)   ← CollectionsKt.emptyList  ← key for patcher
//  13  UTF8 "listOf"     (present so the real "before" bytecode has a
//                          candidate return path other than emptyList)

Uint8List buildFakeAppleConfigurablesImplClass() {
  final cpEntries = [
    cpUtf8('Code'), // 1
    cpUtf8('org/jetbrains/kotlin/konan/target/AppleConfigurablesImpl'), // 2
    cpClass(2), // 3
    cpUtf8('java/lang/Object'), // 4
    cpClass(4), // 5
    cpUtf8('getDependencies'), // 6
    cpUtf8('()Ljava/util/List;'), // 7
    cpUtf8('kotlin/collections/CollectionsKt'), // 8
    cpClass(8), // 9
    cpUtf8('emptyList'), // 10
    cpNameAndType(10, 7), // 11
    cpMethodref(9, 11), // 12
    cpUtf8('listOf'), // 13
  ];

  // Original body stands in for the real "download the sysroot" branch:
  // 12 NOPs, long enough that the 5-byte replacement fits with padding.
  final getDependenciesBody = codeBody(
    maxStack: 2,
    maxLocals: 1,
    code: List<int>.filled(12, 0),
  );

  return Uint8List.fromList([
    ...classFileHeader,
    ...cpSection(cpEntries),
    ...u2(0x0021), // ACC_PUBLIC | ACC_SUPER
    ...u2(3), // this  = AppleConfigurablesImpl
    ...u2(5), // super = Object
    ...u2(0), // interfaces
    ...u2(0), // fields
    ...u2(1), // 1 method
    ...member(
      nameIdx: 6,
      descIdx: 7,
      codeAttrBytes: codeAttr(getDependenciesBody),
    ),
    ...u2(0), // class attrs
  ]);
}

// ── In-memory JAR (ZIP) builder ───────────────────────────────────────────────

Uint8List buildJar(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final MapEntry(:key, :value) in entries.entries) {
    archive.addFile(ArchiveFile(key, value.length, value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
