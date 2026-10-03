import 'package:cli_kit/cli_kit_shared.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

abstract interface class VmServiceConnector {
  WebSocketChannel open(Uri url, {required Duration timeout});
}

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
