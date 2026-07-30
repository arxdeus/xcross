import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// A listening socket, or a live accepted socket, keeps the Dart event loop
/// alive — so a forwarder that is closed but not fully released hangs
/// `xcross flutter run` after the session ends. This tool has already been hit
/// by that twice (a leaked Timer, an uncancelled signal subscription).
///
/// `dart test` reaps its isolates, so it cannot observe this. Only a real child
/// process that must reach exit on its own can.
void main() {
  late Directory dir;

  // Inside the project: `package:xcross` only resolves for a script that can
  // walk up to this package's .dart_tool/package_config.json.
  setUp(() async {
    dir = await Directory('${Directory.current.path}/.dart_tool')
        .createTemp('xcross_fwd');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<Process> startProbe(String body) async {
    final script = File('${dir.path}/probe.dart');
    await script.writeAsString('''
import 'dart:io';
import 'package:xcross/src/device/port_forwarder.dart';

Future<void> main() async {
  // Stands in for the VM Service on the phone.
  final device = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  device.listen((s) => s.listen(s.add, onDone: s.close));

  final forwarder = await PortForwarder.start(
    deviceHost: device.address.address,
    devicePort: device.port,
  );
  stdout.writeln('PORT \${forwarder.localPort}');
$body
  await forwarder.close();
  await device.close();
  // No exit() here on purpose: main returning must be enough.
}
''');
    return Process.start(Platform.resolvedExecutable, ['run', script.path],
        workingDirectory: Directory.current.path);
  }

  Future<int?> waitForExit(Process child) async {
    final code = await child.exitCode.timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        child.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    return code == -1 ? null : code;
  }

  test('exits after close with no connections', () async {
    expect(await waitForExit(await startProbe('')), 0);
  });

  test('exits after close when a peer never lets go', () async {
    // The production case: DevTools runs in its own process and is still
    // attached when the app stops. Nothing but a forced destroy() on our side
    // releases that socket, and an in-process peer cannot reproduce it (its own
    // socket would keep the probe alive regardless).
    final child = await startProbe('  await stdin.first;');
    final port = int.parse(
      (await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .firstWhere((l) => l.startsWith('PORT '))
              .timeout(const Duration(seconds: 25)))
          .substring(5),
    );

    final peer = await Socket.connect(InternetAddress.loopbackIPv4, port);
    addTearDown(peer.destroy);
    peer.write('hold this open');
    await peer.flush();

    // Tell the probe to close the forwarder while we keep holding the socket.
    child.stdin.writeln();
    await child.stdin.flush();

    expect(await waitForExit(child), 0,
        reason: 'close() did not force the still-connected socket shut');
  });
}
