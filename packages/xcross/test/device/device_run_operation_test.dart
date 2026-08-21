import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:test/test.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/device/device_backend.dart';
import 'package:xcross/src/device/device_run_operation.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/models/pack_result.dart';

void main() {
  test('run resolves, terminates, installs, and launches an app', () async {
    final events = <String>[];
    final backend = FakeDeviceBackend(
      device: const Device(name: 'Phone', udid: 'U1', type: ConnectionType.usb),
      events: events,
    );
    final operation = DeviceRunOperation(
      backend: backend,
      osMajorVersion: (_) async => 17,
      terminate: ({required udid, required bundleId}) async {
        events.add('terminate:$udid:$bundleId');
      },
      launch:
          ({
            required udid,
            required bundleId,
            required profile,
            onRestartRequested,
          }) async {
            events.add('launch:$udid:$bundleId:${profile.arguments.single}');
          },
    );

    await operation.run(
      pack: const PackResult(
        outputPath: '/build/App.app',
        bundleId: 'com.example.app',
      ),
      selector: null,
      mode: DeviceSearchMode.all,
      launchProfile: const CoreDeviceLaunchProfile.native(arguments: ['arg']),
    );

    expect(events, [
      'resolve',
      'terminate:U1:com.example.app',
      'install:/build/App.app:U1:com.example.app',
      'launch:U1:com.example.app:arg',
    ]);
  });

  test('run rejects iOS 16 before terminate or install', () async {
    final events = <String>[];
    final operation = DeviceRunOperation(
      backend: FakeDeviceBackend(
        device: const Device(
          name: 'Phone',
          udid: 'U1',
          type: ConnectionType.usb,
        ),
        events: events,
      ),
      osMajorVersion: (_) async => 16,
      terminate: ({required udid, required bundleId}) async {
        events.add('terminate');
      },
      launch:
          ({
            required udid,
            required bundleId,
            required profile,
            onRestartRequested,
          }) async {
            events.add('launch');
          },
    );

    await expectLater(
      operation.run(
        pack: const PackResult(
          outputPath: '/build/App.app',
          bundleId: 'com.example.app',
        ),
        selector: null,
        mode: DeviceSearchMode.all,
        launchProfile: const CoreDeviceLaunchProfile.native(),
      ),
      throwsA(isA<XcrossError>()),
    );
    expect(events, ['resolve']);
  });

  test('run rejects framework output before device discovery', () async {
    final events = <String>[];
    final operation = DeviceRunOperation(
      backend: FakeDeviceBackend(
        device: const Device(
          name: 'Phone',
          udid: 'U1',
          type: ConnectionType.usb,
        ),
        events: events,
      ),
      osMajorVersion: (_) async => 17,
      terminate: ({required udid, required bundleId}) async {
        events.add('terminate');
      },
      launch:
          ({
            required udid,
            required bundleId,
            required profile,
            onRestartRequested,
          }) async {
            events.add('launch');
          },
    );

    await expectLater(
      operation.run(
        pack: const PackResult(
          outputPath: '/build/App.framework',
          bundleId: 'com.example.app',
          kind: PackOutputKind.framework,
        ),
        selector: null,
        mode: DeviceSearchMode.all,
        launchProfile: const CoreDeviceLaunchProfile.native(),
      ),
      throwsA(isA<XcrossError>()),
    );
    expect(events, isEmpty);
  });
}

final class FakeDeviceBackend implements DeviceBackend {
  FakeDeviceBackend({required this.device, required this.events});

  final Device device;
  final List<String> events;

  @override
  Future<Device> resolveDevice({
    required DeviceSearchMode mode,
    String? selector,
  }) async {
    events.add('resolve');
    return device;
  }

  @override
  Future<void> install(
    String appOrIpaPath, {
    required Device device,
    required String bundleId,
  }) async {
    events.add('install:$appOrIpaPath:${device.udid}:$bundleId');
  }
}
