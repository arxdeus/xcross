import 'package:dart_mobile_device/src/models/device_endpoint.dart';

/// How xcross reaches an iOS 17+ device for launch and debug. Callers depend
/// on this contract, never on a concrete transport.
abstract interface class DeviceTransport {
  /// Device-selection arguments for one-shot `pymobiledevice3` invocations,
  /// e.g. `--rsd <host> <port>` or `--userspace --udid <udid>`.
  List<String> get pymdDeviceArgs;

  /// Short transport name for logs and error messages.
  String get description;

  /// Endpoint speaking Apple's debugproxy (GDB-remote) protocol.
  Future<DeviceEndpoint> debugproxyEndpoint();

  /// Endpoint reaching TCP [devicePort] on the device.
  Future<DeviceEndpoint> devicePortEndpoint(int devicePort);

  /// Release every resource this transport owns.
  Future<void> close();
}
