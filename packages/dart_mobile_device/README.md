# dart_mobile_device

iOS device transport for Dart: `pymobiledevice3` wrappers, RSD / userspace
tunnels, port forwarding, and a minimal GDB-remote client.

Used by [xcross](https://github.com/arxdeus/xcross) for iOS 17+ launch, install,
and hot-reload over a device tunnel. Requires Python 3 and
[`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3) on the host.

## Install

```sh
dart pub add dart_mobile_device
```

## Prerequisites

```sh
# Linux
sudo pip3 install --break-system-packages pymobiledevice3

# Windows
py -m pip install -U pymobiledevice3
```

Kernel RSD tunnels need root (Linux) or an Administrator shell (Windows).
Userspace tunnel mode works over usbmux without a TUN device.

## Usage

Supply a `Pymd` composed with the selected host runner, privilege service,
device policy, local HTTP service and console. Supply `DeviceSockets` for
that host. These are caller-owned, not global services. Preparation can
prompt for elevation and leave long-lived tunnel processes running.

### List devices and install

```dart
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd_devices.dart';

Future<void> installApp(Pymd pymd, String appPath) async {
  final service = PymdDevices(pymd);
  final devices = await service.devices();
  for (final device in devices) {
    print('${device.name}  ${device.udid}  ${device.type}');
  }
  if (devices.isEmpty) throw StateError('No reachable device');
  await service.install(appPath, udid: devices.first.udid);
}
```

### Prepare host + resolve transport

```dart
import 'package:dart_mobile_device/shared/network/device_sockets.dart';
import 'package:dart_mobile_device/target/iphone/device/device_prepare.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:dart_mobile_device/target/iphone/device/transport/device_transport_resolver.dart';

Future<void> resolveTransport(Pymd pymd, DeviceSockets sockets, String udid) async {
  await DevicePrepare(pymd).prepare();
  final resolver = DeviceTransportResolver(pymd, sockets: sockets);
  final transport = await resolver.resolve(udid: udid);
  try {
    final debug = await transport.debugproxyEndpoint();
    final vm = await transport.devicePortEndpoint(8181);
    print('debug: $debug, VM service: $vm');
  } finally {
    await transport.close();
  }
}
```

Set `XCROSS_TUNNEL_MODE` to `auto` (default), `kernel`, or `userspace` to
control which transport is built.

### Check tunnel availability

```dart
import 'package:dart_mobile_device/shared/tunnel/tunnel_availability.dart';

Future<void> checkTunnel(TunnelAvailability availability) async {
  print('tunneld reachable: ${await availability.isReachable()}');
}
```

Transport resolution supplies device endpoints without exposing the internal
tunnel discovery model. `TunnelAvailability` checks the local daemon only,
not whether a particular device is reachable.

### Loopback port forward

```dart
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:dart_mobile_device/shared/device/tunnel/port_forwarder.dart';
import 'package:dart_mobile_device/shared/network/device_sockets.dart';

Future<void> forwardPort(Log log, DeviceSockets sockets, String deviceHost) async {
  final forwarder = await PortForwarder.start(
    log: log,
    sockets: sockets,
    deviceHost: deviceHost,
    devicePort: 8181,
  );
  try {
    print('local port: ${forwarder.localPort}');
  } finally {
    await forwarder.close();
  }
}
```

Keep the transport or forwarder open while its endpoints are in use, then
close it in a `finally` block. `deviceHost` is a reachable device address
supplied by the caller.

## API surface

| Type | Role |
| --- | --- |
| `Pymd` / `PymdDevices` | Resolve and invoke `pymobiledevice3` |
| `DevicePrepare` / `DevicePreparation` | Mount DDI and prepare host transport |
| `TunnelAvailability` | Check local tunnel-daemon reachability |
| `DeviceTransportResolver` | Kernel vs userspace transport |
| `PortForwarder` | Advertise a device TCP port on `127.0.0.1` |
| `GdbRemoteClient` | Attach / resume / drain GDB-remote stdout |

## Related

Part of the [xcross](https://github.com/arxdeus/xcross) monorepo. Depends on
[`cli_kit`](https://github.com/arxdeus/xcross/tree/main/packages/cli_kit).
