import 'dart:async';
import 'dart:convert';

import 'package:darwin_sdk_kit/src/cpio_reader.dart';
import 'package:test/test.dart';

import 'test_fixtures.dart';

/// Splits [bytes] into small chunks to force [readCpio] to read across
/// stream-chunk boundaries mid-header and mid-content, not just mid-file.
Stream<List<int>> chunked(List<int> bytes, int chunkSize) async* {
  for (var i = 0; i < bytes.length; i += chunkSize) {
    yield bytes.sublist(i, (i + chunkSize).clamp(0, bytes.length));
  }
}

void main() {
  group('readCpio', () {
    test('decodes multiple entries and stops at TRAILER!!!', () async {
      final stream = [
        buildCpioEntry(name: 'a.txt', data: utf8.encode('hello')),
        buildCpioEntry(name: 'nested/b.bin', data: [1, 2, 3, 4, 5]),
        buildCpioEntry(name: 'empty.txt', data: const []),
        buildCpioTrailer(),
      ].expand((e) => e).toList();

      final entries = await readCpio(Stream.value(stream)).toList();

      expect(entries, hasLength(3));
      expect(entries[0].name, 'a.txt');
      expect(utf8.decode(entries[0].data), 'hello');
      expect(entries[1].name, 'nested/b.bin');
      expect(entries[1].data, [1, 2, 3, 4, 5]);
      expect(entries[2].name, 'empty.txt');
      expect(entries[2].data, isEmpty);
    });

    test('parses mode octal field correctly', () async {
      final stream = [
        buildCpioEntry(name: 'f', data: const [9], mode: 0x81ff),
        buildCpioTrailer(),
      ].expand((e) => e).toList();

      final entries = await readCpio(Stream.value(stream)).toList();
      expect(entries.single.mode, 0x81ff);
    });

    test(
      'reassembles entries split arbitrarily across stream chunks',
      () async {
        final bytes = [
          buildCpioEntry(name: 'a', data: utf8.encode('first file')),
          buildCpioEntry(name: 'bb', data: utf8.encode('second file body')),
          buildCpioTrailer(),
        ].expand((e) => e).toList();

        // 7 bytes doesn't align with any field width above, so headers and
        // content are guaranteed to straddle chunk boundaries.
        final entries = await readCpio(chunked(bytes, 7)).toList();

        expect(entries, hasLength(2));
        expect(entries[0].name, 'a');
        expect(utf8.decode(entries[0].data), 'first file');
        expect(entries[1].name, 'bb');
        expect(utf8.decode(entries[1].data), 'second file body');
      },
    );

    test('throws on bad magic', () {
      final bad = utf8.encode('not a cpio header at all, 76+ bytes long...');
      expect(readCpio(Stream.value(bad)).toList(), throwsA(isException));
    });
  });
}
