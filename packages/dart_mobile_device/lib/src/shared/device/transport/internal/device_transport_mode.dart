/// Which device transport to build.
enum DeviceTransportMode {
  /// Prefer the kernel tunnel, fall back to the userspace tunnel.
  auto,

  /// Kernel tunnel only; fail instead of falling back.
  kernel,

  /// Userspace tunnel only; never touch tunneld or a TUN device.
  userspace,
}
