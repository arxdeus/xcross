/// A user-facing error from device transport, tunnels, or pymobiledevice3.
base class TunnelError implements Exception {
  TunnelError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The host refused the rights the kernel RSD tunnel needs (Administrator on
/// Windows, sudo on POSIX).
///
/// A [TunnelError] on purpose: an unprivileged shell is a *recoverable*
/// condition for `auto` transport mode, which then degrades to the userspace
/// tunnel instead of aborting a build that already succeeded.
final class TunnelPrivilegeError extends TunnelError {
  TunnelPrivilegeError(super.message);
}

/// tunneld answered, but refused to create an RSD tunnel for the device.
///
/// Distinct from every other [TunnelError] because it is *recoverable*:
/// mounting the Developer Disk Image and starting a lockdown tunnel — what
/// `xcross tunnel` does — is exactly what tunneld could not do for itself.
final class TunnelCreationError extends TunnelError {
  TunnelCreationError(super.message);
}
