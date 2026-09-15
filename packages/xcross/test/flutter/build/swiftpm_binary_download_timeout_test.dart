import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_artifact_preparer.dart';

/// These cover the failure that hung Windows CI for six hours: a binary
/// artifact download that connects (or starts) and then never progresses.
/// A bare `HttpClient` waits forever, so the build produced no further output
/// and no error until the job limit killed it.
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('xcross-dl-'));
  tearDown(() => temp.deleteSync(recursive: true));

  File target(String name) => File(p.join(temp.path, name));

  test('aborts when the response headers never arrive', () async {
    // Accepts the connection, then answers nothing at all.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {/* deliberately never responds */});

    final started = Stopwatch()..start();
    await expectLater(
      SwiftPmBinaryArtifactPreparer.downloadArchive(
        Uri.parse('http://${server.address.host}:${server.port}/a.zip'),
        target('a.zip'),
        1 << 20,
        connectTimeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(started.elapsed, lessThan(const Duration(seconds: 20)));
  });

  test('aborts when the body stalls mid-transfer', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      // A long body, of which only the first chunk is ever sent.
      request.response.contentLength = 1 << 20;
      request.response.add(List<int>.filled(16, 1));
      await request.response.flush();
      // Then hang, holding the connection open.
    });

    final started = Stopwatch()..start();
    await expectLater(
      SwiftPmBinaryArtifactPreparer.downloadArchive(
        Uri.parse('http://${server.address.host}:${server.port}/b.zip'),
        target('b.zip'),
        1 << 20,
        stallTimeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(started.elapsed, lessThan(const Duration(seconds: 20)));
  });

  test('a healthy download still succeeds untouched', () async {
    final payload = List<int>.filled(2048, 7);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.add(payload);
      await request.response.close();
    });

    final destination = target('ok.zip');
    await SwiftPmBinaryArtifactPreparer.downloadArchive(
      Uri.parse('http://${server.address.host}:${server.port}/ok.zip'),
      destination,
      1 << 20,
    );
    expect(destination.readAsBytesSync(), payload);
  });

  test('production defaults are bounded, never infinite', () {
    // The regression was the absence of any bound at all.
    expect(
      SwiftPmBinaryArtifactPreparer.downloadConnectTimeout,
      lessThanOrEqualTo(const Duration(minutes: 2)),
    );
    expect(
      SwiftPmBinaryArtifactPreparer.downloadStallTimeout,
      lessThanOrEqualTo(const Duration(minutes: 5)),
    );
    expect(
      SwiftPmBinaryArtifactPreparer.downloadTotalTimeout,
      lessThanOrEqualTo(const Duration(minutes: 30)),
    );
  });
}
