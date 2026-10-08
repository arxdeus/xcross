import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:darwin_sdk_kit/shared/archive/xcode_xip_extractor.dart';
import 'package:darwin_sdk_kit/shared/errors/errors.dart';
import 'package:test/test.dart';

import 'test_fixtures.dart';

void main() {
  group('XcodeXipExtractor.extract', () {
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
            bytes: xzCompress(cpioBytes),
          ),
        ]);

        final xarBytes = buildXar({
          'Content': pbzxBytes,
          'Metadata': utf8.encode('<xml>ignored</xml>'),
        });

        final path = '${tempDir.path}/Xcode.xip';
        await File(path).writeAsBytes(xarBytes);

        final entries = await XcodeXipExtractor(
          MacOSHost(),
        ).extract(path).toList();

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
        XcodeXipExtractor(MacOSHost()).extract(path).toList(),
        throwsA(isA<DarwinSdkError>()),
      );
    });
  });

  group('XcodeXipExtractor.validate', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('xip_validate_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('accepts an archive carrying a Content entry', () async {
      final path = '${tempDir.path}/ok.xip';
      await File(
        path,
      ).writeAsBytes(buildXar({'Content': utf8.encode('payload')}));

      await expectLater(
        XcodeXipExtractor(MacOSHost()).validate(path),
        completes,
      );
    });

    test('rejects a file that is not a XAR archive at all', () async {
      final path = '${tempDir.path}/not_a_xar.xip';
      // The realistic mistake: a wrong path, or an HTML error page saved by
      // a download that silently failed.
      await File(path).writeAsString('<!DOCTYPE html>not your Xcode archive');

      await expectLater(
        XcodeXipExtractor(MacOSHost()).validate(path),
        throwsA(
          isA<DarwinSdkError>().having(
            (error) => error.toString(),
            'message',
            contains('XAR'),
          ),
        ),
      );
    });

    test('rejects a XAR archive with no Content entry', () async {
      final path = '${tempDir.path}/no_content.xip';
      await File(
        path,
      ).writeAsBytes(buildXar({'Metadata': utf8.encode('only metadata')}));

      await expectLater(
        XcodeXipExtractor(MacOSHost()).validate(path),
        throwsA(
          isA<DarwinSdkError>().having(
            (error) => error.toString(),
            'message',
            contains('complete Xcode.xip'),
          ),
        ),
      );
    });
  });
}
