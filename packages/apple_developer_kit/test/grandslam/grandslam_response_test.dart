import 'dart:convert';
import 'dart:typed_data';

import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_response.dart';

void main() {
  test("decodes Apple's bare dictionary payload", () {
    const fragment = '<dict><key>adsid</key><string>123</string></dict>';
    expect(decodePlist(fragment), {'adsid': '123'});
    expect(decodePlistBytes(Uint8List.fromList(utf8.encode(fragment))), {
      'adsid': '123',
    });
  });

  test('surfaces operation errors from Status nested inside Response', () {
    final body = PropertyListSerialization.stringWithPropertyList({
      'Response': {
        'Status': {'ec': -22410, 'em': 'This action could not be completed.'},
      },
    });

    expect(
      () => decodeGrandSlamResponse(body),
      throwsA(
        isA<GrandSlamOperationError>()
            .having((error) => error.code, 'code', -22410)
            .having(
              (error) => error.message,
              'message',
              contains('This action could not be completed.'),
            ),
      ),
    );
  });
}
