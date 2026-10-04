import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';

final class LocalHttp<T extends PlatformHostInterface> {
  LocalHttp(this.host, {required this.createClient});

  final T host;
  final HttpClient Function() createClient;

  static bool isLoopback(String host) {
    final bare = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    if (bare.toLowerCase() == 'localhost') return true;
    return InternetAddress.tryParse(bare)?.isLoopback ?? false;
  }

  String resolveProxy(Uri uri) => isLoopback(uri.host)
      ? 'DIRECT'
      : HttpClient.findProxyFromEnvironment(
          uri,
          environment: host.environment.values,
        );

  HttpClient client({Duration? connectionTimeout}) {
    final client = createClient()..findProxy = resolveProxy;
    if (connectionTimeout != null) client.connectionTimeout = connectionTimeout;
    return client;
  }
}
