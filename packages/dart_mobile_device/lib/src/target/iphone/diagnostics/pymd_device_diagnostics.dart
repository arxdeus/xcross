import 'package:dart_mobile_device/src/models/device.dart';
import 'package:dart_mobile_device/src/os_version.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';
import 'package:dart_mobile_device/src/pymd/pymd_devices.dart';
import 'package:dart_mobile_device/src/shared/diagnostics/device_probe.dart';

final class PymdDeviceDiagnostics implements DeviceDiagnostics {
  PymdDeviceDiagnostics(this.pymd);

  final Pymd pymd;
  late final PymdDevices _devices = PymdDevices(pymd);
  late final OsVersion _osVersion = OsVersion(pymd);

  @override
  Future<String> resolveExecutable() async => (await pymd.resolve()).executable;

  @override
  Future<List<Device>> devices() => _devices.devices();

  @override
  Future<int?> osMajorVersion(Device device) => _osVersion.deviceOSMajorVersion(
    device.udid,
    overTunnel: device.source == DeviceSource.tunneld,
  );
}
