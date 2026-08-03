/// Constants for interactive session keypress handling and DAP markers.
abstract final class DeviceConstants {
  /// Marker printed when the on-device VM Service is live; the DAP scans child
  /// stdout for it (by substring, so a line glyph may precede it) to emit
  /// `flutter.appStarted`. Keep the colon — it is what stops a stray mention of
  /// "vm-service" in the app's own output from being parsed as the URI line.
  ///
  /// Must stay identical to `_vmServiceMarker` in `package:xcross_dap`
  /// (`packages/xcross_dap/lib/src/xcross_dap.dart`).
  static const String vmServiceMarker = 'vm-service: ';

  /// Keycode for 'q' — quits the running session.
  static const int keyQ = 0x71;

  /// Keycode for 'Q' — same as [keyQ] (Windows/Shift).
  static const int keyBigQ = 0x51;

  /// Keycode for 'r' — triggers a hot reload.
  static const int keyR = 0x72;

  /// Keycode for 'R' — triggers a hot restart.
  static const int keyBigR = 0x52;

  /// Keycode for Ctrl-C — terminates the session.
  static const int keyCtrlC = 0x03;

  /// Keycode for Ctrl-D — terminates the session.
  static const int keyCtrlD = 0x04;
}
