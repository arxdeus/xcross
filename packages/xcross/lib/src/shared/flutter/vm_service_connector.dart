import 'package:cli_kit/shared/http/local_http.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

@internal
abstract interface class VmServiceConnector {
  WebSocketChannel open(Uri url, {required Duration timeout});
}

@internal
final class LocalVmServiceConnector<T extends PlatformHostInterface>
    implements VmServiceConnector {
  LocalVmServiceConnector(this.localHttp);

  final LocalHttp<T> localHttp;
  @override
  WebSocketChannel open(Uri url, {required Duration timeout}) =>
      LocalHttp.isLoopback(url.host)
      ? IOWebSocketChannel.connect(
          url,
          customClient: localHttp.client(),
          connectTimeout: timeout,
        )
      : WebSocketChannel.connect(url);
}
