# dart_mobile_device

iOS device transport for Dart — pymobiledevice3 wrappers, RSD / userspace
tunnels, port forwarding, and GDB remote.

```dart
import 'package:dart_mobile_device/dart_mobile_device.dart';

final devices = await PymdDevices.list();
await TunnelDaemon().ensureRunning();
```
