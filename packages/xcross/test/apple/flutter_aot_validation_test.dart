import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../tool/verify_flutter_aot.dart' as verifier;

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('aot-dylib-validation-');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  File binary(List<int> commands) {
    final file = File(
      '${temporary.path}/Fixture.app/Frameworks/App.framework/App',
    )..createSync(recursive: true);
    file.writeAsBytesSync(_dylib(commands));
    return file;
  }

  test('rejects a dylib with no dependencies', () {
    final image = verifier.ArmMachO.read(binary([]).path);
    expect(image.requireDylibDependency, throwsStateError);
  });

  test('the install name is not a dependency', () {
    final image = verifier.ArmMachO.read(binary([0xd]).path);
    expect(image.requireDylibDependency, throwsStateError);
  });

  for (final command in [0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023]) {
    test('accepts dependency command 0x${command.toRadixString(16)}', () {
      final image = verifier.ArmMachO.read(binary([0xd, command]).path);
      expect(image.requireDylibDependency, returnsNormally);
    });
  }

  test(
    'app verification reports the loader failure before snapshot checks',
    () {
      binary([0xd]);
      expect(
        () => verifier.main(['${temporary.path}/Fixture.app']),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('missing dylib dependency'), contains('-lSystem')),
          ),
        ),
      );
    },
  );
}

// A thin arm64 dylib with real dylib_command payloads. No sections or
// snapshots are needed to reproduce the missing-dependency loader failure.
Uint8List _dylib(List<int> commands) {
  final encoded = <Uint8List>[];
  for (final command in commands) {
    final name = utf8.encode(
      command == 0xd
          ? '@rpath/App.framework/App'
          : '/usr/lib/libSystem.B.dylib',
    );
    final size = (24 + name.length + 1 + 7) & ~7;
    final bytes = Uint8List(size);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, command, Endian.little);
    data.setUint32(4, size, Endian.little);
    data.setUint32(8, 24, Endian.little);
    bytes.setRange(24, 24 + name.length, name);
    encoded.add(bytes);
  }
  final size = encoded.fold<int>(0, (size, command) => size + command.length);
  final bytes = Uint8List(32 + size);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0xfeedfacf, Endian.little);
  data.setUint32(4, 0x0100000c, Endian.little);
  data.setUint32(12, 6, Endian.little);
  data.setUint32(16, commands.length, Endian.little);
  data.setUint32(20, size, Endian.little);
  data.setUint32(24, 0x85, Endian.little); // NOUNDEFS | DYLDLINK | TWOLEVEL
  var offset = 32;
  for (final command in encoded) {
    bytes.setRange(offset, offset + command.length, command);
    offset += command.length;
  }
  return bytes;
}
