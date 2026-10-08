import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/errors/errors.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';

import 'support/log_output.dart';

@internal
final class DownloadTestClient implements HttpClient {
  DownloadTestClient(this.responses, {this.closeError});
  final Error? closeError;
  final List<DownloadTestResponse> responses;
  int attempts = 0;
  bool closed = false;
  bool? forced;
  final List<DownloadTestRequest> requests = [];
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final request = DownloadTestRequest(responses[attempts++]);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
    forced = force;
    if (closeError != null) throw closeError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@internal
final class DownloadTestRequest implements HttpClientRequest {
  DownloadTestRequest(this.response);
  final DownloadTestResponse response;
  @override
  bool followRedirects = false;
  @override
  int maxRedirects = 0;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@internal
final class DownloadTestResponse extends Stream<List<int>>
    implements HttpClientResponse {
  DownloadTestResponse(
    this.statusCode,
    this.chunks, {
    this.error,
    this.errorStack,
  });
  final StackTrace? errorStack;
  @override
  final int statusCode;
  final List<List<int>> chunks;
  final Object? error;
  bool drained = false;
  @override
  int get contentLength =>
      chunks.fold(0, (length, chunk) => length + chunk.length);
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      (error == null
              ? Stream<List<int>>.fromIterable(chunks)
              : Stream<List<int>>.error(error!, errorStack))
          .listen(
            onData,
            onError: onError,
            onDone: onDone,
            cancelOnError: cancelOnError,
          );
  @override
  Future<E> drain<E>([E? futureValue]) {
    drained = true;
    return super.drain<E>(futureValue);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late RecordingLogOutput output;
  late Log log;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('download-test-');
    output = RecordingLogOutput();
    log = Log(output: output);
  });
  tearDown(() async {
    log.stopStep();
    await temp.delete(recursive: true);
  });

  test('injected client downloads chunks and closes each transfer', () async {
    final clients = <DownloadTestClient>[];
    final downloader = Downloader(
      log: log,
      createClient: () {
        final client = DownloadTestClient([
          DownloadTestResponse(200, [
            utf8.encode('hello'),
            utf8.encode(' world'),
          ]),
        ]);
        clients.add(client);
        return client;
      },
    );
    for (var i = 0; i < 2; i++) {
      final destination = File('${temp.path}/nested/file$i.txt');
      await downloader.downloadToFile(
        'https://example.invalid/file.txt',
        destination,
      );
      expect(await destination.readAsString(), 'hello world');
    }
    expect(clients, hasLength(2));
    for (final client in clients) {
      expect(client.closed, isTrue);
      expect(client.forced, isTrue);
      expect(client.requests.single.followRedirects, isTrue);
      expect(client.requests.single.maxRedirects, 10);
    }
    expect(output.lines.last, contains('11 B'));
  });

  test('HTTP retries drain failures then preserve successful bytes', () async {
    final failed = DownloadTestResponse(503, [utf8.encode('unavailable')]);
    final client = DownloadTestClient([
      failed,
      DownloadTestResponse(200, [utf8.encode('ok')]),
    ]);
    final destination = File('${temp.path}/file.txt');
    await Downloader(createClient: () => client, log: log).downloadToFile(
      'https://example.invalid/file.txt',
      destination,
      retryDelay: Duration.zero,
    );
    expect(client.attempts, 2);
    expect(failed.drained, isTrue);
    expect(await destination.readAsString(), 'ok');
    expect(client.closed, isTrue);
  });

  test('exhausted retries close client and report error', () async {
    final client = DownloadTestClient([
      DownloadTestResponse(404, []),
      DownloadTestResponse(404, []),
    ]);
    await expectLater(
      Downloader(createClient: () => client, log: log).downloadToFile(
        'https://example.invalid/missing',
        File('${temp.path}/file.txt'),
        maxAttempts: 2,
        retryDelay: Duration.zero,
      ),
      throwsA(isA<CliError>()),
    );
    expect(client.attempts, 2);
    expect(client.closed, isTrue);
    expect(output.lines, isEmpty);
  });

  test(
    'destination write failure marks progress failed and closes client',
    () async {
      final client = DownloadTestClient([
        DownloadTestResponse(200, [utf8.encode('hello')]),
      ]);
      await expectLater(
        Downloader(createClient: () => client, log: log).downloadToFile(
          'https://example.invalid/file.txt',
          File(temp.path),
          label: 'file.txt',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(output.lines, ['file.txt']);
      expect(client.closed, isTrue);
    },
  );

  test('stream failure marks progress failed and closes client', () async {
    final error = StateError('stream broken');
    final client = DownloadTestClient([
      DownloadTestResponse(200, [], error: error),
    ]);
    await expectLater(
      Downloader(createClient: () => client, log: log).downloadToFile(
        'https://example.invalid/file.txt',
        File('${temp.path}/file.txt'),
        label: 'file.txt',
      ),
      throwsA(same(error)),
    );
    expect(output.lines.last, 'file.txt');
    expect(client.closed, isTrue);
  });

  test(
    'diagnostic and client cleanup failures preserve stream error and stack',
    () async {
      final output = ThrowingLogOutput(failStdoutAt: 1);
      final error = StateError('stream failed');
      final stack = StackTrace.fromString('original stream stack');
      final client = DownloadTestClient([
        DownloadTestResponse(200, [], error: error, errorStack: stack),
      ], closeError: StateError('client close failed'));
      try {
        await Downloader(
          createClient: () => client,
          log: Log(output: output),
        ).downloadToFile(
          'https://example.invalid/file.txt',
          File('${temp.path}/file.txt'),
        );
        fail('must throw');
      } on Object catch (actual, actualStack) {
        expect(actual, same(error));
        expect(actualStack.toString(), stack.toString());
      }
      expect(output.stdoutAttempts, 1);
      expect(client.closed, isTrue);
      expect(client.forced, isTrue);
    },
  );

  test('invalid attempt count rejects before acquiring a client', () async {
    var acquired = false;
    final downloader = Downloader(
      log: log,
      createClient: () {
        acquired = true;
        return DownloadTestClient([]);
      },
    );
    await expectLater(
      downloader.downloadToFile(
        'https://example.invalid/file',
        File('${temp.path}/file'),
        maxAttempts: 0,
      ),
      throwsArgumentError,
    );
    expect(acquired, isFalse);
  });
}
