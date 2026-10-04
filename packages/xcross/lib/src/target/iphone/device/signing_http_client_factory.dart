import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/device/signing_http_client_factory.dart';

@internal
final class HttpSigningClientFactory implements SigningHttpClientFactory {
  const HttpSigningClientFactory();
  @override
  http.Client create() => http.Client();
}
