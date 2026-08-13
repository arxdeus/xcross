import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross/src/flutter/hot_reload/dart_vm_service_client.dart';

/// End-to-end check against a REAL Dart VM Service.
///
/// The pure decoders are unit-tested elsewhere; what broke in practice was the
/// plumbing: `streamId` is a sibling of `event` in the `streamNotify` wire
/// format, not a field of it, so a listener switching on `event['streamId']`
/// silently matched nothing and no app output was ever forwarded. Only a live
/// VM can catch that class of mistake.
void main() {
  test(
    'surfaces streamId so Stdout and Stderr are distinguishable',
    () async {
      final dir = await Directory.systemTemp.createTemp('xcross_vm_out');
      addTearDown(() => dir.delete(recursive: true));
      final script = File('${dir.path}/target.dart');
      await script.writeAsString('''
import 'dart:async';
import 'dart:developer';
import 'dart:io';

void main() {
  // Keep printing: the test subscribes only after the VM is up, and anything
  // emitted before that is genuinely gone.
  Timer.periodic(const Duration(milliseconds: 100), (_) {
    print('to-stdout');
    stderr.writeln('to-stderr');
    log('to-log', name: 'probe');
  });
}
''');

      final child = await Process.start(Platform.resolvedExecutable, [
        'run',
        '--enable-vm-service=0',
        '--disable-service-auth-codes',
        script.path,
      ], environment: _noLoopbackProxy());
      addTearDown(() => child.kill(ProcessSignal.sigkill));

      // "The Dart VM service is listening on http://127.0.0.1:<port>/"
      final banner = await child.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .firstWhere((l) => l.contains('listening on'))
          .timeout(const Duration(seconds: 30));
      final httpUri = Uri.parse(
        RegExp(r'(http://\S+)').firstMatch(banner)!.group(1)!,
      );
      final wsUri = httpUri.replace(scheme: 'ws', path: '${httpUri.path}ws');

      final vm = DartVmServiceClient();
      await vm.connect(wsUri);
      addTearDown(vm.close);

      final seen = <String>{};
      final done = Completer<void>();
      vm.events.listen((event) {
        if (event['streamId'] case final String id) seen.add(id);
        if (seen.containsAll(const {'Stdout', 'Stderr', 'Logging'}) &&
            !done.isCompleted) {
          done.complete();
        }
      });
      await vm.streamListen('Stdout');
      await vm.streamListen('Stderr');
      await vm.streamListen('Logging');

      await done.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => fail('never saw all three streams; saw: $seen'),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

/// Environment for the child VM with loopback exempted from any proxy.
///
/// The VM boots DDS by connecting to its own service on 127.0.0.1, and
/// dart:io honours `http_proxy` while its `no_proxy` parser understands only
/// literal hosts (not the usual `127.0.0.0/8`). On a machine with a
/// system-wide proxy the child dies with "Could not start the VM service:
/// Connection closed before full header was received" and this test times
/// out for reasons that have nothing to do with the code under test.
Map<String, String> _noLoopbackProxy() {
  final env = Map<String, String>.from(Platform.environment)
    ..removeWhere((key, _) => key.toLowerCase().endsWith('_proxy'));
  env['no_proxy'] = 'localhost,127.0.0.1,::1';
  env['NO_PROXY'] = env['no_proxy']!;
  return env;
}
