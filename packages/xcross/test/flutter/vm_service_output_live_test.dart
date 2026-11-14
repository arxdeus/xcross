import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/http/local_http.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/hot_reload/dart_vm_service_client.dart';
import 'package:xcross/src/shared/flutter/vm_service_connector.dart';

import 'flutter_test_log.dart';

/// End-to-end check against a REAL Dart VM Service.
///
/// The pure decoders are unit-tested elsewhere; what broke in practice was the
/// plumbing: `streamId` is a sibling of `event` in the `streamNotify` wire
/// format, not a field of it, so a listener switching on `event['streamId']`
/// silently matched nothing and no app output was ever forwarded. Only a live
/// VM can catch that class of mistake.
void main() {
  test('surfaces streamId so Stdout and Stderr are distinguishable', () async {
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
    // Depending on SDK version and platform the banner can land on stdout or
    // stderr, so watch both and keep the output for a useful failure message.
    final output = StringBuffer();
    final bannerFound = Completer<String>();
    Future<void> watch(Stream<List<int>> stream) => stream
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
          output.writeln(line);
          if (line.contains('listening on') && !bannerFound.isCompleted) {
            bannerFound.complete(line);
          }
        })
        .asFuture<void>();

    final drained = Future.wait([watch(child.stdout), watch(child.stderr)]);
    unawaited(
      // Exit can be observed before the pipes are drained; classify the
      // failure only once all of the child's output has been collected.
      Future.wait([child.exitCode, drained]).then((results) {
        final code = results.first;
        if (bannerFound.isCompleted) return;
        if (output.toString().contains(_missingServiceSnapshot)) {
          // SDK packaging defect (seen on Dart 3.14.0 windows-arm64): the new
          // dart_runtime_service_vm snapshot is absent, so no VM in this SDK
          // can host a service at all. Not something this code can affect.
          bannerFound.complete(_missingServiceSnapshot);
        } else {
          bannerFound.completeError(
            StateError(
              'VM exited with $code before the service banner:\n'
              '$output',
            ),
          );
        }
      }),
    );
    final banner = await bannerFound.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => fail('no VM service banner; output:\n$output'),
    );
    if (banner == _missingServiceSnapshot) {
      markTestSkipped('SDK ships without a VM service snapshot:\n$output');
      return;
    }
    final httpUri = Uri.parse(
      RegExp(r'(http://\S+)').firstMatch(banner)!.group(1)!,
    );
    final wsUri = httpUri.replace(scheme: 'ws', path: '${httpUri.path}ws');

    final vm = DartVmServiceClient(
      log: testFlutterLog(),
      connector: LocalVmServiceConnector(
        LocalHttp(LinuxHost(), createClient: HttpClient.new),
      ),
    );
    await vm.connect(wsUri);
    addTearDown(vm.close);

    final seen = <String>{};
    final done = Completer<void>();
    vm.events.listen((event) {
      final Object? streamId = event['streamId'];
      if (streamId case final String id) seen.add(id);
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
  }, timeout: const Timeout(Duration(seconds: 60)));
}

const _missingServiceSnapshot = 'Unable to find VM service snapshot';

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
