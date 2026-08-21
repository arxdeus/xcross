import 'package:dart_mobile_device/src/models/device_endpoint.dart';

/// How xcross reaches an iOS 17+ device for launch and debug. Callers depend
/// on this contract, never on a concrete transport.
abstract interface class DeviceTransport {
  /// Device-selection arguments for one-shot `pymobiledevice3` invocations,
  /// e.g. `--rsd <host> <port>` or `--userspace --udid <udid>`.
  List<String> get pymdDeviceArgs;

  /// [pymdDeviceArgs] for *extra* one-shot commands run alongside the live
  /// session, or null when this transport has none that are safe to reuse.
  ///
  /// The userspace transport's args (`--userspace --udid …`) establish a new
  /// in-process tunnel per invocation: fine for the session's own commands,
  /// which is what those args exist for, but a second concurrent tunnel to a
  /// device that already has one stalls for minutes. Convenience lookups
  /// (installed-app lists and the like) must fall back to plain usbmux
  /// instead of paying that cost.
  List<String>? get sideChannelDeviceArgs => pymdDeviceArgs;

  /// Short transport name for logs and error messages.
  String get description;

  /// Endpoint speaking Apple's debugproxy (GDB-remote) protocol.
  Future<DeviceEndpoint> debugproxyEndpoint();

  /// Endpoint reaching TCP [devicePort] on the device.
  Future<DeviceEndpoint> devicePortEndpoint(int devicePort);

  /// Release every resource this transport owns.
  Future<void> close();
}
