import 'package:http/http.dart' as http;

import 'package:xcross/src/shared/device/signing_http_client_factory.dart';

final class HttpSigningClientFactory implements SigningHttpClientFactory {
  const HttpSigningClientFactory();
  @override
  http.Client create() => http.Client();
}
