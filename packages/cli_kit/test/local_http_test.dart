import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/http/local_http.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';

@internal
final class RecordingHttpClient implements HttpClient {
  String Function(Uri)? proxy;
  Duration? timeout;
  @override
  set findProxy(String Function(Uri)? value) => proxy = value;
  @override
  set connectionTimeout(Duration? value) => timeout = value;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected HTTP operation');
}

void main() {
  test('local HTTP uses explicit client factory and host proxy snapshot', () {
    final client = RecordingHttpClient();
    final http = LocalHttp(
      LinuxHost(environment: {'http_proxy': 'http://proxy.example:8080'}),
      createClient: () => client,
    );
    expect(
      http.client(connectionTimeout: const Duration(seconds: 3)),
      same(client),
    );
    expect(client.timeout, const Duration(seconds: 3));
    expect(client.proxy!(Uri.parse('http://localhost:1234')), 'DIRECT');
    expect(client.proxy!(Uri.parse('http://127.0.0.1')), 'DIRECT');
    expect(client.proxy!(Uri.parse('http://[::1]')), 'DIRECT');
    expect(
      client.proxy!(Uri.parse('http://remote.example')),
      'PROXY proxy.example:8080',
    );
  });

  test('host proxy configurations remain instance scoped', () {
    final first = LocalHttp(
      LinuxHost(environment: {'http_proxy': 'one:80'}),
      createClient: RecordingHttpClient.new,
    );
    final second = LocalHttp(
      LinuxHost(environment: {'http_proxy': 'two:81'}),
      createClient: RecordingHttpClient.new,
    );
    final uri = Uri.parse('http://remote.example');
    expect(first.resolveProxy(uri), 'PROXY one:80');
    expect(second.resolveProxy(uri), 'PROXY two:81');
    expect(LocalHttp.isLoopback('LOCALHOST'), isTrue);
    expect(LocalHttp.isLoopback('example.com'), isFalse);
  });
}
