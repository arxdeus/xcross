import 'package:meta/meta.dart';

/// The part of an HTTP response the release lookup cares about: either a body
/// or the `Location` of a redirect.
@immutable
final class HttpResult {
  const HttpResult({this.body, this.location});

  final String? body;
  final String? location;
}
