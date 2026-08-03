import 'dart:io';

import 'package:test/test.dart';
import 'package:apple_developer_kit/src/apple_http_client.dart';

void main() {
  test('loads the published Apple Inc. root certificate', () {
    expect(createAppleSecurityContext(), isA<SecurityContext>());
  });
}
