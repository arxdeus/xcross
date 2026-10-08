import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

@internal
abstract interface class SigningHttpClientFactory {
  http.Client create();
}
