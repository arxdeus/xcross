import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross/src/darwinsdk/xar_reader.dart';

import 'test_fixtures.dart';

void main() {
  group('findXarEntry', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('xar_reader_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test("locates a named entry's absolute heap byte range", () async {
      final xarBytes = buildXar({
        'Content': utf8.encode('hello world'),
        'Metadata': utf8.encode('meta!'),
      });
      final path = '${tempDir.path}/synthetic.xar';
      await File(path).writeAsBytes(xarBytes);
      final file = await File(path).open();
      addTearDown(file.close);

      final content = await findXarEntry(file, 'Content');
      expect(content, isNotNull);
      await file.setPosition(content!.offset);
      final contentBytes = await file.read(content.length);
      expect(utf8.decode(contentBytes), 'hello world');

      final metadata = await findXarEntry(file, 'Metadata');
      expect(metadata, isNotNull);
      await file.setPosition(metadata!.offset);
      final metadataBytes = await file.read(metadata.length);
      expect(utf8.decode(metadataBytes), 'meta!');

      // Entries are distinct, non-overlapping heap regions.
      expect(metadata.offset, content.offset + content.length);
    });

    test('returns null for a missing entry name', () async {
      final xarBytes = buildXar({'Content': utf8.encode('x')});
      final path = '${tempDir.path}/synthetic.xar';
      await File(path).writeAsBytes(xarBytes);
      final file = await File(path).open();
      addTearDown(file.close);

      expect(await findXarEntry(file, 'DoesNotExist'), isNull);
    });

    test('throws on bad magic', () async {
      final path = '${tempDir.path}/not_xar.bin';
      await File(path).writeAsBytes(List.filled(32, 0));
      final file = await File(path).open();
      addTearDown(file.close);

      expect(() => findXarEntry(file, 'Content'), throwsA(isException));
    });
  });
}
