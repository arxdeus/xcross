/// Constants for device connectivity and tunneld.
abstract final class TunnelConstants {
  /// VM service port used when launching the app on device.
  static const int vmServicePort = 12345;

  /// RSD service name for the Apple remote debug proxy.
  static const String debugproxyService =
      'com.apple.internal.dt.remote.debugproxy';

  /// Default tunneld REST API base URL.
  static const String tunneldUrl = 'http://127.0.0.1:49151/';
}
