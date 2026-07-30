// Visual smoke test for the console UI. Run in a real terminal to see the
// spinner + progress bar; pipe it to see the ANSI-less rendering.
import 'dart:async';
import 'dart:io';

import 'package:xcross/src/constants.dart';
import 'package:xcross/src/util/download.dart';
import 'package:xcross/src/util/logging.dart';

Future<void> main() async {
  logInfo('Device', 'iPhone Mind ${ansi.subtle('00008030-000664292232802E')}');

  await logStep('Resolving dependencies', _work(600));

  // A download inside a step: the bar takes over the line, the step still ✓s.
  final fetch = beginStep('Fetching Flutter engine artifacts');
  await _fakeDownload('Flutter iOS engine', 279 * 1024 * 1024);
  fetch.done();

  await logStep('Compiling Dart kernel', _work(900));
  await logStep('Building App.framework', _work(400));

  // A step with a collapsing grey log tail, like `xtool install`.
  final install = beginStep('Signing and installing');
  for (final line in const [
    'Fetching signing certificate',
    'Registering app id com.test.abra',
    'Provisioning profile: iOS Team Provisioning',
    'Signing Frameworks/Flutter.framework',
    'Signing Frameworks/App.framework',
    'Uploading to device (12.4 MB)',
  ]) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    install.log('$line\n');
  }
  install.done();

  await logStep('Waiting for RSD tunnel', _work(500));
  await logStep('Debugger attached', _work(200));
  logInfo('App', 'com.test.abra ${ansi.subtle('debug/JIT, hot reload')}');
  logInfo(DeviceConstants.vmServiceMarker, 'ws://127.0.0.1:46269/ws');
  logInfo('Hot reload ready '
      '${ansi.subtle('— r reload  ·  R restart  ·  q quit')}');

  await logStep('Hot reload', _work(4400)).then((_) {});
  logWarn('expression evaluation unavailable: no isolate');
  try {
    await logStep('Hot restart', () async => throw StateError('vm rejected'));
  } catch (_) {}
}

Future<void> Function() _work(int ms) =>
    () => Future<void>.delayed(Duration(milliseconds: ms));

/// Exercise the real download path against a local server, so the progress bar
/// shown here is exactly the one users see.
Future<void> _fakeDownload(String label, int total) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  const chunks = 25;
  final chunk = List<int>.filled(total ~/ chunks, 0);
  unawaited(server.first.then((req) async {
    req.response.contentLength = chunk.length * chunks;
    for (var i = 0; i < chunks; i++) {
      req.response.add(chunk);
      await req.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await req.response.close();
  }));

  final dest = File('${Directory.systemTemp.path}/xcross-tui-demo.bin');
  await downloadToFile('http://127.0.0.1:${server.port}/artifacts.zip', dest,
      label: label);
  await server.close(force: true);
  await dest.delete();
}
