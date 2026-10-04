import 'package:cli_kit/shared/http/local_http.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:dart_mobile_device/shared/tunnel/tunnel_availability.dart';
import 'package:dart_mobile_device/src/target/iphone/device/tunnel/tunnel_daemon.dart';

final class PymdTunnelAvailability implements TunnelAvailability {
  PymdTunnelAvailability({required this.localHttp});

  final LocalHttp<PlatformHostInterface> localHttp;

  @override
  Future<bool> isReachable() => TunnelDaemon.isReachable(localHttp: localHttp);
}
