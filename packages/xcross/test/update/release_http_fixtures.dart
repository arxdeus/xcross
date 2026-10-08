import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:meta/meta.dart';

@internal
final class FixtureReleaseHttpClient implements HttpClient {
  FixtureReleaseHttpClient(this.response);
  final Future<HttpClientResponse> Function() response;
  final requests = <FixtureReleaseHttpRequest>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    final request = FixtureReleaseHttpRequest(uri, response);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@internal
final class FixtureReleaseHttpRequest implements HttpClientRequest {
  FixtureReleaseHttpRequest(this.uri, this.response);
  @override
  final Uri uri;
  final Future<HttpClientResponse> Function() response;
  @override
  bool followRedirects = true;
  @override
  final FixtureReleaseHttpHeaders headers = FixtureReleaseHttpHeaders();
  @override
  Future<HttpClientResponse> close() => response();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@internal
final class FixtureReleaseHttpHeaders implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = '$value';
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@internal
final class FixtureReleaseHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  FixtureReleaseHttpResponse({
    this.statusCode = 200,
    String body = '',
    String? location,
  }) : data = utf8.encode(body) {
    if (location != null) headers.set(HttpHeaders.locationHeader, location);
  }
  final List<int> data;
  @override
  final int statusCode;
  @override
  final FixtureReleaseHttpHeaders headers = FixtureReleaseHttpHeaders();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(data).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
