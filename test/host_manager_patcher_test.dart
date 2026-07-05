import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:xcross/src/build/host_manager_patcher.dart';

import 'support/class_file_builder.dart';
import 'support/class_file_inspector.dart';
import 'support/fake_classes.dart';

// JVM opcode aliases — only where a name clearly aids reading.
const int iconst1 = 0x04; // ICONST_1
const int ireturn = 0xAC; // IRETURN
const int aload0 = 0x2A; // ALOAD_0
const int invokeVirtual = 0xB6; // INVOKEVIRTUAL
const int areturn = 0xB0; // ARETURN
const int vreturn = 0xB1; // RETURN (void)

void main() {
  // ── CP parser: Long/Double consume two slots ──────────────────────────────

  group('CP double-slot (Long/Double)', () {
    test('Long entry in CP does not corrupt subsequent index', () {
      // The HostManager fake class has a Long at CP slot 14/15.
      // If the patcher mishandles double-slot entries it throws or fails to
      // find the Methodref at slot 10.  Successful completion is the assertion.
      expect(
        () => patchHostManagerClassBytes(buildFakeHostManagerClass()),
        returnsNormally,
      );
    });

    test('patched class round-trips magic and version unchanged', () {
      final patched = patchHostManagerClassBytes(buildFakeHostManagerClass());
      expect(patched.sublist(0, 4), equals([0xCA, 0xFE, 0xBA, 0xBE]));
      expect(patched[4], equals(0x00)); // minor high
      expect(patched[5], equals(0x00)); // minor low
      expect(patched[6], equals(0x00)); // major high
      expect(patched[7], equals(0x41)); // major 65 = Java 21
    });
  });

  // ── replaceMethodCode: code_length preserved, StackMapTable stripped ──────

  group('patchHostManagerClassBytes bytecode rewriting', () {
    late Uint8List patched;

    setUp(() {
      patched = patchHostManagerClassBytes(buildFakeHostManagerClass());
    });

    test('patched bytes differ from original', () {
      expect(patched, isNot(equals(buildFakeHostManagerClass())));
    });

    test('isEnabled Code has ICONST_1 + IRETURN as last two bytes', () {
      // Original code_length=10, new code is 2 bytes → padded with 8 NOPs.
      final cf = parseForInspection(patched);
      expect(cf.isEnabledCodeBody[8], equals(iconst1)); // ICONST_1
      expect(cf.isEnabledCodeBody[9], equals(ireturn)); // IRETURN
    });

    test('isEnabled Code preserves code_length = 10', () {
      expect(parseForInspection(patched).isEnabledCodeLength, equals(10));
    });

    test('isEnabled Code exception table is emptied', () {
      expect(
        parseForInspection(patched).isEnabledExceptionCount,
        equals(0),
      );
    });

    test('isEnabled Code has no StackMapTable inner attribute', () {
      expect(
        parseForInspection(patched).isEnabledInnerAttrNames,
        isNot(contains('StackMapTable')),
      );
    });

    test('getEnabled Code has ALOAD_0 + INVOKEVIRTUAL + ARETURN tail', () {
      // New code is 5 bytes: [ALOAD_0, INVOKEVIRTUAL, hi, lo, ARETURN]
      // padded with 5 NOPs at the front (code_length=10).
      final body = parseForInspection(patched).getEnabledCodeBody;
      expect(body[5], equals(aload0)); // ALOAD_0
      expect(body[6], equals(invokeVirtual)); // INVOKEVIRTUAL
      expect(body[7], equals(0x00)); // Methodref index high byte
      expect(body[8], equals(0x0A)); // Methodref index low byte (= 10)
      expect(body[9], equals(areturn)); // ARETURN
    });
  });

  // ── getTargetValues Methodref index resolution ────────────────────────────

  group('getTargetValues Methodref resolution', () {
    test('resolves Methodref at CP index 10 in fake class', () {
      final patched =
          patchHostManagerClassBytes(buildFakeHostManagerClass());
      final body = parseForInspection(patched).getEnabledCodeBody;
      final invokeIdx = (body[7] << 8) | body[8];
      expect(invokeIdx, equals(10));
    });

    test('throws StateError when getTargetValues Methodref is missing', () {
      // Class has the right method names but no Methodref for getTargetValues.
      final cpEntries = [
        cpUtf8('Code'), // 1
        cpUtf8('isEnabled'), // 2
        cpUtf8('(Lorg/jetbrains/kotlin/konan/target/KonanTarget;)Z'), // 3
        cpUtf8('getEnabled'), // 4
        cpUtf8('()Ljava/util/List;'), // 5
        cpUtf8('SomeClass'), // 6
        cpClass(6), // 7
        cpUtf8('java/lang/Object'), // 8
        cpClass(8), // 9
      ];
      final body = codeBody(
        maxStack: 1,
        maxLocals: 1,
        code: List<int>.filled(5, 0),
      );
      final raw = Uint8List.fromList([
        ...classFileHeader,
        ...cpSection(cpEntries),
        ...u2(0x0021),
        ...u2(7), // this = SomeClass
        ...u2(9), // super = Object
        ...u2(0), // interfaces
        ...u2(0), // fields
        ...u2(2), // methods
        ...member(nameIdx: 2, descIdx: 3, codeAttrBytes: codeAttr(body)),
        ...member(nameIdx: 4, descIdx: 5, codeAttrBytes: codeAttr(body)),
        ...u2(0), // class attrs
      ]);
      expect(
        () => patchHostManagerClassBytes(raw),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ── ObjCExport patch ──────────────────────────────────────────────────────

  group('patchObjCExportClassBytes', () {
    test('returns non-null for class with target method', () {
      expect(patchObjCExportClassBytes(buildFakeObjCExportClass()), isNotNull);
    });

    test('returns null for class without target method', () {
      final cpEntries = [
        cpUtf8('Code'), // 1
        cpUtf8('someOtherMethod'), // 2
        cpUtf8('()V'), // 3
        cpUtf8('Foo'), // 4
        cpClass(4), // 5
        cpUtf8('java/lang/Object'), // 6
        cpClass(6), // 7
      ];
      final body = codeBody(
        maxStack: 0,
        maxLocals: 0,
        code: [vreturn],
      );
      final raw = Uint8List.fromList([
        ...classFileHeader,
        ...cpSection(cpEntries),
        ...u2(0x0021),
        ...u2(5), // this = Foo
        ...u2(7), // super = Object
        ...u2(0), // interfaces
        ...u2(0), // fields
        ...u2(1), // 1 method
        ...member(nameIdx: 2, descIdx: 3, codeAttrBytes: codeAttr(body)),
        ...u2(0), // class attrs
      ]);
      expect(patchObjCExportClassBytes(raw), isNull);
    });

    test('patched method code ends with RETURN (0xB1)', () {
      // code_length=5, new code=[RETURN] → last byte of the code array is 0xB1.
      final patched = patchObjCExportClassBytes(buildFakeObjCExportClass())!;
      expect(findLastCodeByte(patched), equals(vreturn));
    });
  });

  // ── JAR-level patch (in-memory) ───────────────────────────────────────────

  group('patchKotlinNativeJar', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('patcher_test_');
    });

    tearDown(() async {
      await tmpDir.delete(recursive: true);
    });

    test('returns false when marker already present', () async {
      final jar = File('${tmpDir.path}/test.jar');
      await jar.writeAsBytes(buildJar({
        jarMarkerPath: [112, 97, 116, 99, 104, 101, 100, 10],
        hostManagerClassEntry: buildFakeHostManagerClass().toList(),
      }));
      expect(patchKotlinNativeJar(jar.path), isFalse);
    });

    test('returns false when no patchable classes in JAR', () async {
      final jar = File('${tmpDir.path}/test.jar');
      await jar.writeAsBytes(buildJar({
        'some/other/Class.class': [0xCA, 0xFE, 0xBA, 0xBE],
      }));
      expect(patchKotlinNativeJar(jar.path), isFalse);
    });

    test('returns true and adds marker when HostManager present', () async {
      final jar = File('${tmpDir.path}/test.jar');
      await jar.writeAsBytes(buildJar({
        hostManagerClassEntry: buildFakeHostManagerClass().toList(),
        'other/Entry.class': [1, 2, 3, 4],
      }));

      expect(patchKotlinNativeJar(jar.path), isTrue);

      final updated = ZipDecoder().decodeBytes(await jar.readAsBytes());
      expect(updated.files.map((f) => f.name).toSet(), contains(jarMarkerPath));
    });

    test('is idempotent: second call returns false', () async {
      final jar = File('${tmpDir.path}/test.jar');
      await jar.writeAsBytes(buildJar({
        hostManagerClassEntry: buildFakeHostManagerClass().toList(),
      }));

      expect(patchKotlinNativeJar(jar.path), isTrue);
      expect(patchKotlinNativeJar(jar.path), isFalse);
    });

    test('returns false for non-existent file', () {
      expect(
        patchKotlinNativeJar('${tmpDir.path}/missing.jar'),
        isFalse,
      );
    });

    test('non-patchable entries are copied unchanged', () async {
      final jar = File('${tmpDir.path}/test.jar');
      final payload = [9, 8, 7, 6, 5];
      await jar.writeAsBytes(buildJar({
        hostManagerClassEntry: buildFakeHostManagerClass().toList(),
        'META-INF/MANIFEST.MF': payload,
      }));

      patchKotlinNativeJar(jar.path);

      final updated = ZipDecoder().decodeBytes(await jar.readAsBytes());
      final manifest =
          updated.files.firstWhere((f) => f.name == 'META-INF/MANIFEST.MF');
      expect((manifest.content as List).toList(), equals(payload));
    });
  });
}
