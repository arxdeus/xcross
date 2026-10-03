import 'package:dart_mobile_device/src/models/device.dart';

abstract interface class DeviceDiagnostics {
  Future<String> resolveExecutable();
  Future<List<Device>> devices();
  Future<int?> osMajorVersion(Device device);
}
