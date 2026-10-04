import 'package:meta/meta.dart';

/// Which device transport to build.
@internal
enum DeviceTransportMode {
  /// Prefer the kernel tunnel, fall back to the userspace tunnel.
  auto,

  /// Kernel tunnel only; fail instead of falling back.
  kernel,

  /// Userspace tunnel only; never touch tunneld or a TUN device.
  userspace,
}
