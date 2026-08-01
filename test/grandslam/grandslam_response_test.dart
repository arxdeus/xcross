import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/grandslam/grandslam_response.dart';

void main() {
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
