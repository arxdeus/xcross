import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcross/src/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/util/errors.dart';

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
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          contains('is longer than'),
        ),
      ),
    );
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
      throwsA(isA<XcrossError>()),
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
