import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross/src/util/apple_http_client.dart';

void main() {
  test('loads the published Apple Inc. root certificate', () {
    expect(createAppleSecurityContext(), isA<SecurityContext>());
  });
}
