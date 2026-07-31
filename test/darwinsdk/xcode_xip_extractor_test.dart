import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross/src/darwinsdk/xcode_xip_extractor.dart';
import 'package:xcross/src/util/errors.dart';

import 'test_fixtures.dart';

void main() {
  group('extractXcodeXipContent', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('xip_extractor_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test(
      'decodes a synthetic .xip end-to-end: XAR -> pbzx -> cpio entries',
      () async {
        final cpioBytes = [
          buildCpioEntry(name: 'a.txt', data: utf8.encode('hello')),
          buildCpioEntry(name: 'dir/b.bin', data: const [10, 20, 30]),
          buildCpioTrailer(),
        ].expand((e) => e).toList();

        final pbzxBytes = buildPbzx([
          PbzxChunk(
            decompressedSize: cpioBytes.length,
            bytes: await xzCompress(cpioBytes),
          ),
        ]);

        final xarBytes = buildXar({
          'Content': pbzxBytes,
          'Metadata': utf8.encode('<xml>ignored</xml>'),
        });

        final path = '${tempDir.path}/Xcode.xip';
        await File(path).writeAsBytes(xarBytes);

        final entries = await extractXcodeXipContent(path).toList();

        expect(entries, hasLength(2));
        expect(entries[0].name, 'a.txt');
        expect(utf8.decode(entries[0].data), 'hello');
        expect(entries[1].name, 'dir/b.bin');
        expect(entries[1].data, [10, 20, 30]);
      },
    );

    test('throws when the XAR has no Content entry', () async {
      final xarBytes = buildXar({'Metadata': utf8.encode('only metadata')});
      final path = '${tempDir.path}/no_content.xip';
      await File(path).writeAsBytes(xarBytes);

      expect(
        extractXcodeXipContent(path).toList(),
        throwsA(isA<XcrossError>()),
      );
    });
  });
}
