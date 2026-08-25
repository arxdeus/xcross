import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/flutter/errors.dart';

const _idDylib = 0x0d;
const _loadDylib = 0x0c;
const _loadWeakDylib = 0x80000018;
const _reexportDylib = 0x8000001f;
const _loadUpwardDylib = 0x80000023;

void main() {
  test('rewrites the dylib ID and produced dylib dependencies', () {
    final bytes = _macho([
      (_idDylib, '/private/tmp/build/libAggregate.dylib'),
      (_loadDylib, '/private/tmp/build/libDirect.dylib'),
      (_loadWeakDylib, '/private/tmp/build/libWeak.dylib'),
      (_reexportDylib, '/private/tmp/build/libReexport.dylib'),
      (_loadUpwardDylib, '/private/tmp/build/libUpward.dylib'),
      (_loadDylib, '/usr/lib/libSystem.B.dylib'),
    ]);

    expect(
      MachODylibRewriter.rewriteBytes(
        bytes,
        dylibName: 'libAggregate.dylib',
        producedDylibNames: {
          'libAggregate.dylib',
          'libDirect.dylib',
          'libWeak.dylib',
          'libReexport.dylib',
          'libUpward.dylib',
        },
      ),
      isTrue,
    );

    expect(_dylibNames(bytes), [
      '@rpath/libAggregate.dylib',
      '@rpath/libDirect.dylib',
      '@rpath/libWeak.dylib',
      '@rpath/libReexport.dylib',
      '@rpath/libUpward.dylib',
      '/usr/lib/libSystem.B.dylib',
    ]);
  });

  test('rejects a replacement longer than the existing string', () {
    final bytes = _macho([(_idDylib, 'x')]);

    expect(
      () => MachODylibRewriter.rewriteBytes(
        bytes,
        dylibName: 'libAggregate.dylib',
        producedDylibNames: const {},
      ),
      throwsA(
        isA<FlutterBuildError>().having(
          (error) => error.message,
          'message',
          contains('does not fit'),
        ),
      ),
    );
  });

  test('repairs a unique malformed dedicated Objective-C selref', () {
    final fixture = _objcMacho();

    expect(
      MachODylibRewriter.rewriteBytes(
        fixture.bytes,
        dylibName: 'libPlugin.dylib',
        producedDylibNames: const {},
      ),
      isTrue,
    );
    expect(
      ByteData.sublistView(
        fixture.bytes,
      ).getUint64(fixture.firstSelrefOffset, Endian.little),
      fixture.fooAddress,
    );

    final repaired = Uint8List.fromList(fixture.bytes);
    expect(
      MachODylibRewriter.rewriteBytes(
        fixture.bytes,
        dylibName: 'libPlugin.dylib',
        producedDylibNames: const {},
      ),
      isFalse,
    );
    expect(fixture.bytes, repaired);
  });

  test('retargets a fast stub to an existing matching selref', () {
    final fixture = _objcMacho(hasMatchingSelref: true);
    final data = ByteData.sublistView(fixture.bytes);
    final oldAdrp = data.getUint32(fixture.stubOffset, Endian.little);
    final oldLdr = data.getUint32(fixture.stubOffset + 4, Endian.little);

    expect(
      MachODylibRewriter.rewriteBytes(
        fixture.bytes,
        dylibName: 'libPlugin.dylib',
        producedDylibNames: const {},
      ),
      isTrue,
    );
    expect((
      data.getUint32(fixture.stubOffset, Endian.little),
      data.getUint32(fixture.stubOffset + 4, Endian.little),
    ), isNot((oldAdrp, oldLdr)));
    expect(
      data.getUint64(fixture.firstSelrefOffset, Endian.little),
      fixture.barAddress,
      reason: 'the wrong but valid selref must not be overwritten',
    );
  });

  test('rejects repair of a malformed selref shared by fast stubs', () {
    final fixture = _objcMacho(sharedMalformedSelref: true);
    final original = Uint8List.fromList(fixture.bytes);

    expect(
      () => MachODylibRewriter.rewriteBytes(
        fixture.bytes,
        dylibName: 'libPlugin.dylib',
        producedDylibNames: const {},
      ),
      throwsA(
        isA<FlutterBuildError>().having(
          (error) => error.message,
          'message',
          contains('no safe selref repair'),
        ),
      ),
    );
    expect(fixture.bytes, original, reason: 'validation must precede mutation');
  });

  test('ignores Objective-C data in non-ARM64 Mach-O files', () {
    final fixture = _objcMacho();
    ByteData.sublistView(fixture.bytes).setUint32(4, 0x01000007, Endian.little);
    final original = Uint8List.fromList(fixture.bytes);

    expect(
      MachODylibRewriter.rewriteBytes(
        fixture.bytes,
        dylibName: 'libPlugin.dylib',
        producedDylibNames: const {},
      ),
      isFalse,
    );
    expect(fixture.bytes, original);
  });

  test('rejects load commands outside the declared command bounds', () {
    final bytes = Uint8List(40);
    final data = ByteData.sublistView(bytes);
    data
      ..setUint32(0, 0xfeedfacf, Endian.little)
      ..setUint32(16, 1, Endian.little)
      ..setUint32(20, 8, Endian.little)
      ..setUint32(32, _idDylib, Endian.little)
      ..setUint32(36, 24, Endian.little);

    expect(
      () => MachODylibRewriter.rewriteBytes(
        bytes,
        dylibName: 'libAggregate.dylib',
        producedDylibNames: const {},
      ),
      throwsA(isA<FlutterBuildError>()),
    );
  });
}

Uint8List _macho(List<(int, String)> commands) {
  final encodedNames = [
    for (final command in commands) utf8.encode(command.$2),
  ];
  final commandSizes = [
    for (final name in encodedNames) (24 + name.length + 1 + 7) & ~7,
  ];
  final commandsSize = commandSizes.fold(0, (sum, size) => sum + size);
  final bytes = Uint8List(32 + commandsSize);
  final data = ByteData.sublistView(bytes);
  data
    ..setUint32(0, 0xfeedfacf, Endian.little)
    ..setUint32(16, commands.length, Endian.little)
    ..setUint32(20, commandsSize, Endian.little);

  var offset = 32;
  for (var index = 0; index < commands.length; index++) {
    data
      ..setUint32(offset, commands[index].$1, Endian.little)
      ..setUint32(offset + 4, commandSizes[index], Endian.little)
      ..setUint32(offset + 8, 24, Endian.little);
    bytes.setRange(
      offset + 24,
      offset + 24 + encodedNames[index].length,
      encodedNames[index],
    );
    offset += commandSizes[index];
  }
  return bytes;
}

({
  Uint8List bytes,
  int stubOffset,
  int firstSelrefOffset,
  int fooAddress,
  int barAddress,
})
_objcMacho({
  bool hasMatchingSelref = false,
  bool sharedMalformedSelref = false,
}) {
  const textVm = 0x100000000;
  const dataVm = 0x100002000;
  const stubOffset = 0x1000;
  const namesOffset = 0x1040;
  const selrefsOffset = 0x2000;
  const symbolsOffset = 0x2080;
  const stringsOffset = 0x20c0;
  const fooAddress = textVm + namesOffset;
  const barAddress = fooAddress + 4;
  final stubCount = sharedMalformedSelref ? 2 : 1;
  final symbolNames = sharedMalformedSelref
      ? [r'_objc_msgSend$foo', r'_objc_msgSend$bar']
      : [r'_objc_msgSend$foo'];
  final stringTable = <int>[0];
  final stringIndexes = <int>[];
  for (final name in symbolNames) {
    stringIndexes.add(stringTable.length);
    stringTable
      ..addAll(utf8.encode(name))
      ..add(0);
  }

  const segmentCommandSize = 72 + 2 * 80;
  const commandSize = segmentCommandSize * 2 + 24;
  final bytes = Uint8List(0x2100);
  final data = ByteData.sublistView(bytes);
  data
    ..setUint32(0, 0xfeedfacf, Endian.little)
    ..setUint32(4, 0x0100000c, Endian.little)
    ..setUint32(12, 6, Endian.little)
    ..setUint32(16, 3, Endian.little)
    ..setUint32(20, commandSize, Endian.little);

  var commandOffset = 32;
  _putSegment(
    bytes,
    commandOffset,
    segment: '__TEXT',
    vmAddress: textVm,
    fileOffset: 0,
    fileSize: 0x2000,
    sections: const [
      ('__objc_stubs', stubOffset, stubOffset, 24),
      ('__objc_methname', namesOffset, namesOffset, 8),
    ],
  );
  commandOffset += segmentCommandSize;
  _putSegment(
    bytes,
    commandOffset,
    segment: '__DATA',
    vmAddress: dataVm,
    fileOffset: 0x2000,
    fileSize: 0x100,
    sections: const [
      ('__objc_selrefs', 0, selrefsOffset, 16),
      ('__unused', 0x10, selrefsOffset + 0x10, 0),
    ],
  );
  commandOffset += segmentCommandSize;
  data
    ..setUint32(commandOffset, 2, Endian.little)
    ..setUint32(commandOffset + 4, 24, Endian.little)
    ..setUint32(commandOffset + 8, symbolsOffset, Endian.little)
    ..setUint32(commandOffset + 12, stubCount, Endian.little)
    ..setUint32(commandOffset + 16, stringsOffset, Endian.little)
    ..setUint32(commandOffset + 20, stringTable.length, Endian.little);

  bytes.setRange(namesOffset, namesOffset + 8, utf8.encode('foo\x00bar\x00'));
  data
    ..setUint64(
      selrefsOffset,
      hasMatchingSelref ? barAddress : 0xdeadbeef,
      Endian.little,
    )
    ..setUint64(
      selrefsOffset + 8,
      hasMatchingSelref ? fooAddress : barAddress,
      Endian.little,
    );
  for (var index = 0; index < stubCount; index++) {
    final address = textVm + stubOffset + index * 12;
    _putStub(data, stubOffset + index * 12, address, dataVm);
    final symbolOffset = symbolsOffset + index * 16;
    data
      ..setUint32(symbolOffset, stringIndexes[index], Endian.little)
      ..setUint8(symbolOffset + 4, 0x0e)
      ..setUint8(symbolOffset + 5, 1)
      ..setUint64(symbolOffset + 8, address, Endian.little);
  }
  bytes.setRange(
    stringsOffset,
    stringsOffset + stringTable.length,
    stringTable,
  );
  return (
    bytes: bytes,
    stubOffset: stubOffset,
    firstSelrefOffset: selrefsOffset,
    fooAddress: fooAddress,
    barAddress: barAddress,
  );
}

void _putSegment(
  Uint8List bytes,
  int offset, {
  required String segment,
  required int vmAddress,
  required int fileOffset,
  required int fileSize,
  required List<(String, int, int, int)> sections,
}) {
  final data = ByteData.sublistView(bytes);
  data
    ..setUint32(offset, 0x19, Endian.little)
    ..setUint32(offset + 4, 72 + sections.length * 80, Endian.little)
    ..setUint64(offset + 24, vmAddress, Endian.little)
    ..setUint64(offset + 32, fileSize, Endian.little)
    ..setUint64(offset + 40, fileOffset, Endian.little)
    ..setUint64(offset + 48, fileSize, Endian.little)
    ..setUint32(offset + 64, sections.length, Endian.little);
  _putName(bytes, offset + 8, segment);
  for (var index = 0; index < sections.length; index++) {
    final section = sections[index];
    final sectionOffset = offset + 72 + index * 80;
    _putName(bytes, sectionOffset, section.$1);
    _putName(bytes, sectionOffset + 16, segment);
    data
      ..setUint64(sectionOffset + 32, vmAddress + section.$2, Endian.little)
      ..setUint64(sectionOffset + 40, section.$4, Endian.little)
      ..setUint32(sectionOffset + 48, section.$3, Endian.little);
  }
}

void _putName(Uint8List bytes, int offset, String name) {
  final encoded = ascii.encode(name);
  bytes.setRange(offset, offset + encoded.length, encoded);
}

void _putStub(ByteData data, int offset, int address, int refAddress) {
  final pageDelta = ((refAddress & ~0xfff) - (address & ~0xfff)) ~/ 0x1000;
  final immediate = pageDelta & 0x1fffff;
  data
    ..setUint32(
      offset,
      0x90000001 | (immediate & 3) << 29 | ((immediate >> 2) & 0x7ffff) << 5,
      Endian.little,
    )
    ..setUint32(
      offset + 4,
      0xf9400021 | ((refAddress & 0xfff) ~/ 8) << 10,
      Endian.little,
    )
    ..setUint32(offset + 8, 0x14000000, Endian.little);
}

List<String> _dylibNames(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final count = data.getUint32(16, Endian.little);
  final names = <String>[];
  var offset = 32;
  for (var index = 0; index < count; index++) {
    final size = data.getUint32(offset + 4, Endian.little);
    final nameOffset = data.getUint32(offset + 8, Endian.little);
    final start = offset + nameOffset;
    var end = start;
    while (bytes[end] != 0) {
      end++;
    }
    names.add(utf8.decode(bytes.sublist(start, end)));
    offset += size;
  }
  return names;
}
