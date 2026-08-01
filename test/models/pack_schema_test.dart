import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/models/config/pack_schema.dart';
import 'package:xcross/src/util/errors.dart';

void main() {
  group('OrgIdSpecifier', () {
    test('forms bundle id as orgId.product', () {
      expect(
        const OrgIdSpecifier('com.example').formBundleId('MyApp'),
        'com.example.MyApp',
      );
    });
  });

  group('BundleIdSpecifier', () {
    test('forms bundle id as the literal bundle id, ignoring product', () {
      expect(
        const BundleIdSpecifier(
          'com.foo.bar',
        ).formBundleId('ignored-product-name'),
        'com.foo.bar',
      );
    });
  });

  group('PackSchema.defaultSchema', () {
    test('uses the com.example org id specifier', () {
      final schema = PackSchema.defaultSchema();
      expect(schema.idSpecifier, isA<OrgIdSpecifier>());
      expect((schema.idSpecifier as OrgIdSpecifier).orgId, 'com.example');
      expect(schema.infoPath, isNull);
    });
  });

  group('PackSchema.fromFile', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('xcross_pack_schema-');
    });

    tearDown(() => tmp.delete(recursive: true));

    Future<PackSchema> load(String content) async {
      final path = p.join(tmp.path, 'xcross.yml');
      await File(path).writeAsString(content);
      return PackSchema.fromFile(path);
    }

    test('parses orgID into an OrgIdSpecifier with null infoPath', () async {
      final schema = await load('version: 1\norgID: com.test\n');

      expect(schema.idSpecifier, isA<OrgIdSpecifier>());
      expect((schema.idSpecifier as OrgIdSpecifier).orgId, 'com.test');
      expect(schema.infoPath, isNull);
    });

    test('parses bundleID into a BundleIdSpecifier', () async {
      final schema = await load('version: 1\nbundleID: com.test.App\n');

      expect(schema.idSpecifier, isA<BundleIdSpecifier>());
      expect(
        (schema.idSpecifier as BundleIdSpecifier).bundleId,
        'com.test.App',
      );
    });

    test('parses infoPath when present', () async {
      final schema = await load(
        'version: 1\norgID: com.test\ninfoPath: custom/Info.plist\n',
      );

      expect(schema.infoPath, 'custom/Info.plist');
    });

    test(
      'bundleID takes precedence when both bundleID and orgID are set',
      () async {
        final schema = await load(
          'version: 1\nbundleID: com.test.App\norgID: com.test\n',
        );

        expect(schema.idSpecifier, isA<BundleIdSpecifier>());
      },
    );

    test('throws on unsupported schema version', () async {
      await expectLater(
        load('version: 2\norgID: com.test\n'),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('Unsupported schema version'),
          ),
        ),
      );
    });

    test('throws when neither orgID nor bundleID is specified', () async {
      await expectLater(
        load('version: 1\n'),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('Must specify either'),
          ),
        ),
      );
    });

    test('names xcross.yml when the document is not a YAML mapping', () async {
      await expectLater(
        load('hello'),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            'xcross.yml: invalid document',
          ),
        ),
      );
    });
  });
}
