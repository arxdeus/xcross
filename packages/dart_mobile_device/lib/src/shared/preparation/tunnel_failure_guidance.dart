String describeDeviceTunnelFailure(List<String> recent) {
  final detail = recent.join('\n');
  final buffer = StringBuffer();
  if (detail.isNotEmpty) buffer.writeln(detail);
  if (detail.contains('Device is not connected')) {
    buffer.writeln(
      'The device is no longer visible to usbmuxd. Unplug and replug the '
      'cable (or unlock and re-trust the phone), then retry.',
    );
  } else if (detail.contains('usbmuxd')) {
    buffer.writeln(
      'usbmuxd is not reachable. Restore the host device connection service, '
      'then retry.',
    );
  }
  return buffer.toString();
}
