import 'dart:io';

import 'package:apple_developer_kit/src/apple_http_client.dart';
import 'package:test/test.dart';

void main() {
  test('loads the published Apple Inc. root certificate', () {
    expect(createAppleSecurityContext(), isA<SecurityContext>());
  });
}
