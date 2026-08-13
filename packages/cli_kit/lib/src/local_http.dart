import 'dart:io';

/// HTTP clients that never send loopback traffic through an HTTP proxy.
///
/// Dart's default `HttpClient` honours `http_proxy`/`all_proxy` but its
/// `no_proxy` parsing only matches literal hosts and suffixes, so the very
/// common `no_proxy=localhost,127.0.0.0/8,::1` does NOT exempt
/// `127.0.0.1`. On a machine running a system-wide proxy (Clash, v2ray,
/// corporate PAC setups) every local request xcross makes — the tunneld
/// REST API on 127.0.0.1:49151, the forwarded VM Service — is then relayed
/// to the proxy, which answers `502` for a host it cannot reach. That looks
/// exactly like "tunneld did not come up" even though the daemon is healthy.
abstract final class LocalHttp {
  /// Whether [host] addresses this machine, so it must bypass any proxy.
  static bool isLoopback(String host) {
    final bare = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    if (bare == 'localhost') return true;
    final address = InternetAddress.tryParse(bare);
    return address?.isLoopback ?? false;
  }

  /// Proxy resolver that keeps loopback traffic direct and otherwise defers
  /// to the environment, so real outbound requests still use the proxy.
  static String resolveProxy(Uri uri) => isLoopback(uri.host)
      ? 'DIRECT'
      : HttpClient.findProxyFromEnvironment(uri);

  /// An [HttpClient] wired to [resolveProxy].
  static HttpClient client({Duration? connectionTimeout}) {
    final client = HttpClient()..findProxy = resolveProxy;
    if (connectionTimeout != null) client.connectionTimeout = connectionTimeout;
    return client;
  }
}
