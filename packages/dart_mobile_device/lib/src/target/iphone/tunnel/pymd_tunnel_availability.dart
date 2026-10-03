import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/src/shared/tunnel/tunnel_availability.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_daemon.dart';

final class PymdTunnelAvailability implements TunnelAvailability {
  PymdTunnelAvailability({required this.localHttp});

  final LocalHttp<PlatformHostInterface> localHttp;

  @override
  Future<bool> isReachable() => TunnelDaemon.isReachable(localHttp: localHttp);
}
