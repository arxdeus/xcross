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

### List devices and install

```dart
import 'package:dart_mobile_device/dart_mobile_device.dart';

final devices = await PymdDevices.devices();
for (final d in devices) {
  print('${d.name}  ${d.udid}  ${d.type}');
}

await PymdDevices.install('/path/to/App.app', udid: devices.first.udid);
```

### Prepare host + resolve transport

```dart
// Mount DDI, ensure tunneld, start lockdown RSD tunnel (elevated).
await DevicePrepare.prepare();

final transport = await DeviceTransportResolver.resolve(udid: udid);
try {
  final debug = await transport.debugproxyEndpoint();
  final vm = await transport.devicePortEndpoint(8181);
  // …
} finally {
  await transport.close();
}
```

Set `XCROSS_TUNNEL_MODE` to `auto` (default), `kernel`, or `userspace` to
control which transport is built.

### Discover an existing RSD tunnel

```dart
final tunnel = await TunnelDiscovery.discoverTunnel(udid: udid);
print('${tunnel.address}:${tunnel.port}');
```

### Loopback port forward

```dart
final forwarder = await PortForwarder.start(
  deviceHost: tunnel.address,
  devicePort: 8181,
);
print('local port: ${forwarder.localPort}');
await forwarder.close();
```

## API surface

| Type | Role |
| --- | --- |
| `Pymd` / `PymdDevices` | Resolve and invoke `pymobiledevice3` |
| `DevicePrepare` / `TunnelDaemon` | Mount DDI, keep tunneld alive |
| `TunnelDiscovery` | Poll tunneld REST API for an RSD tunnel |
| `DeviceTransportResolver` | Kernel vs userspace transport |
| `PortForwarder` | Advertise a device TCP port on `127.0.0.1` |
| `GdbRemoteClient` | Attach / resume / drain GDB-remote stdout |

## Related

Part of the [xcross](https://github.com/arxdeus/xcross) monorepo. Depends on
[`cli_kit`](https://github.com/arxdeus/xcross/tree/main/packages/cli_kit).
