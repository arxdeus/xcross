import 'package:http/http.dart' as http;

abstract interface class SigningHttpClientFactory {
  http.Client create();
}
