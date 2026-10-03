import 'package:http/http.dart' as http;

abstract interface class SigningHttpClientFactory {
  http.Client create();
}

final class HttpSigningClientFactory implements SigningHttpClientFactory {
  const HttpSigningClientFactory();
  @override
  http.Client create() => http.Client();
}
