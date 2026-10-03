import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/models/tunnel.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';

final class DeveloperDiskImage {
  const DeveloperDiskImage(this.pymd, {required this.describeFailure});
  final Pymd pymd;
  final String Function(List<String>) describeFailure;

  Future<void> mountOverRsd(Tunnel tunnel) => Log.logStep(
    'Mounting Developer Disk Image',
    () => pymd.run([
      'mounter',
      'auto-mount',
      '--rsd',
      tunnel.address,
      '${tunnel.port}',
    ], timeout: const Duration(seconds: 30)),
  );

  Future<void> mountUsb() async {
    final argv = await pymd.elevatedArgs(['mounter', 'auto-mount']);
    Log.logTrace('[pymobiledevice3] mounting DDI: ${argv.join(' ')}');
    await Log.logStep('Mounting Developer Disk Image', () async {
      final result = await pymd.runner.run(
        argv.first,
        argv.sublist(1),
        environment: pymd.usbmuxEnvironment(),
      );
      Log.logTrace(result.stdout.trim());
      final stderr = result.stderr.trim();
      if (result.exitCode != 0 ||
          (stderr.contains('Device is not connected') ||
              stderr.contains('Failed to connect to usbmuxd socket'))) {
        throw TunnelError(
          'mounter auto-mount failed (exit ${result.exitCode}).\n'
          '${describeFailure(stderr.isEmpty ? const [] : stderr.split('\n'))}'
          'Retry manually:\n'
          '    ${pymd.elevatedCommand('mounter auto-mount')}',
        );
      }
    });
  }
}
