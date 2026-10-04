import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device_shared.dart';
import 'package:frontend_server_kit/frontend_server_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xcross/src/flutter/hot_reload/dart_vm_service_client.dart';
import 'package:xcross/src/flutter/hot_reload/hot_reload_controller.dart';
import 'package:xcross/src/flutter/models/hot_reload_config.dart';
import 'package:xcross/src/shared/flutter/vm_service_connector.dart';

import 'flutter_test_log.dart';

void main() {
  test(
    'mapped warm kernel and reload upload stay selected and preserve bytes',
    () async {
      final temp = await Directory.systemTemp.createTemp('reload-selected-');
      addTearDown(() => temp.delete(recursive: true));
      final root = '/reload-${p.basename(temp.path)}';
      final hostPaths = PosixPaths(currentDirectory: root);
      final files = ReloadMappedFileSystem(root, temp.path, hostPaths.context);
      final host = LinuxHost(paths: hostPaths, fileSystem: files);
      await files.directory('$root/lib').create(recursive: true);
      await files.file('$root/lib/main.dart').writeAsString('initial');
      await files.directory('$root/artifacts').create();
      final resultPath = '$root/artifacts/result with spaces.dill';
      final bytes = [0, 1, 127, 255, 80];
      await files.file(resultPath).writeAsBytes(bytes);
      await files.file('$root/artifacts/warm.dill').writeAsBytes([9]);
      final process = ReloadCompilerFactory(resultPath);
      final rpc = ReloadRpcChannel();
      final vm = DartVmServiceClient(
        log: testFlutterLog(),
        connector: ReloadConnector(rpc),
      );
      await vm.connect(Uri.parse('ws://selected.invalid/ws'));
      final uploads = <ReloadHttpClient>[];
      final controller = HotReloadController(
        config: HotReloadConfig(
          dart: 'owned-dart',
          frontendServer: 'frontend_server_aot.snapshot',
          sdkRoot: '/sdk',
          packageConfig: '$root/missing.json',
          entrypoint: '$root/lib/main.dart',
          projectRoot: root,
          outputDill: '$root/output/app.dill',
          warmDill: '$root/artifacts/warm.dill',
        ),
        log: testFlutterLog(),
        localHttp: LocalHttp<PlatformHostInterface>(
          host,
          createClient: () {
            final client = ReloadHttpClient();
            uploads.add(client);
            return client;
          },
        ),
        vm: vm,
        vmService: const DeviceEndpoint(host: 'selected.invalid', port: 1234),
        processFactory: process,
        diagnostics: (_) {},
      );
      addTearDown(controller.close);
      await controller.initialSync();
      expect(
        process.arguments,
        containsAllInOrder([
          '--initialize-from-dill',
          '$root/artifacts/warm.dill',
        ]),
      );
      expect(uploads, isEmpty);
      await files.file('$root/lib/main.dart').writeAsString('changed');
      expect(await controller.reload(), isTrue);
      expect(uploads, hasLength(1));
      final upload = uploads.single;
      expect(GZipCodec().decode(upload.request.bytes), bytes);
      expect(upload.request.contentLength, upload.request.bytes.length);
      expect(upload.closed, isTrue);
      expect(upload.request.headers.values['dev_fs_name'], 'xcross');
      expect(
        utf8.decode(
          base64Decode(
            upload.request.headers.values['dev_fs_uri_b64']! as String,
          ),
        ),
        'org-dartlang-devfs://selected/main.dart.dill',
      );
      expect(
        rpc.methods,
        containsAllInOrder(['reloadSources', 'ext.flutter.reassemble']),
      );
      expect(process.transport.commands.last, 'accept\n');
      expect(files.lookups, contains(resultPath));
      expect(await files.file(resultPath).readAsBytes(), bytes);
      expect(Directory(root).existsSync(), isFalse);
      await controller.close();
      expect(process.transport.closes, 1);
    },
  );
}

final class ReloadMappedFileSystem implements HostFileSystemInterface {
  ReloadMappedFileSystem(this.root, this.backing, this.paths);
  final String root;
  final String backing;
  final p.Context paths;
  final lookups = <String>[];
  String map(String path) {
    lookups.add(path);
    if (paths.isWithin(backing, path)) return path;
    final absolute = paths.absolute(path);
    if (absolute == root) return backing;
    if (!paths.isWithin(root, absolute)) {
      throw StateError('outside selected namespace: $path');
    }
    return paths.join(backing, paths.relative(absolute, from: root));
  }

  @override
  File file(String path) => File(map(path));
  @override
  Directory directory(String path) => Directory(map(path));
  @override
  Link link(String path) => Link(map(path));
  @override
  void makeExecutable(String path) => throw UnsupportedError('unused');
  @override
  void setPermissions(String path, int mode) =>
      throw UnsupportedError('unused');
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      throw UnsupportedError('unused');
}

final class ReloadCompilerFactory implements CompilerProcessFactory {
  ReloadCompilerFactory(String result)
    : transport = ReloadCompilerTransport(result);
  final ReloadCompilerTransport transport;
  List<String>? arguments;
  @override
  Future<CompilerTransport> start(
    String executable,
    List<String> arguments,
  ) async {
    this.arguments = arguments;
    return transport;
  }
}

final class ReloadCompilerTransport implements CompilerTransport {
  ReloadCompilerTransport(this.result);
  final String result;
  final lines = StreamController<String>();
  final commands = <String>[];
  int closes = 0;
  @override
  Stream<String> get output => lines.stream;
  @override
  Stream<String> get diagnostics => const Stream.empty();
  @override
  Future<int> get exitCode async => 0;
  @override
  Future<void> send(String command) async {
    commands.add(command);
    if (command.startsWith('compile ') || command.startsWith('recompile ')) {
      lines.add('result boundary');
      lines.add('boundary $result 0');
    }
  }

  @override
  Future<void> close() async {
    closes++;
    await lines.close();
  }
}

final class ReloadConnector implements VmServiceConnector {
  ReloadConnector(this.channel);
  final ReloadRpcChannel channel;
  @override
  WebSocketChannel open(Uri url, {required Duration timeout}) => channel;
}

final class ReloadRpcChannel implements WebSocketChannel {
  final incoming = StreamController<Object?>();
  final methods = <String>[];
  @override
  late final WebSocketSink sink = ReloadRpcSink(this);
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  Future<void> get ready async {}
  void respond(Object? data) {
    final frame = jsonDecode(data! as String) as Map<String, dynamic>;
    final method = frame['method'] as String;
    methods.add(method);
    final result = switch (method) {
      '_createDevFS' => {'uri': 'org-dartlang-devfs://selected/'},
      '_flutter.listViews' => {
        'views': [
          {
            'id': 'view',
            'isolate': {'id': 'root'},
          },
        ],
      },
      'reloadSources' => {'success': true},
      _ => <String, Object?>{},
    };
    incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected channel operation: $invocation');
}

final class ReloadRpcSink implements WebSocketSink {
  ReloadRpcSink(this.channel);
  final ReloadRpcChannel channel;
  @override
  void add(dynamic data) => channel.respond(data);
  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      channel.incoming.close();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected socket operation: $invocation');
}

final class ReloadHttpClient implements HttpClient {
  final request = ReloadHttpRequest();
  bool closed = false;
  @override
  set findProxy(String Function(Uri)? value) {}
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> putUrl(Uri uri) async => request;
  @override
  void close({bool force = false}) => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected HTTP operation: $invocation');
}

final class ReloadHttpRequest implements HttpClientRequest {
  final bytes = <int>[];
  @override
  final ReloadHttpHeaders headers = ReloadHttpHeaders();
  @override
  int contentLength = 0;
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  Future<HttpClientResponse> close() async => ReloadHttpResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected request operation: $invocation');
}

final class ReloadHttpHeaders implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = value;
  @override
  set contentType(ContentType? value) {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected header operation: $invocation');
}

final class ReloadHttpResponse implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  Future<E> drain<E>([E? futureValue]) async => futureValue as E;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected response operation: $invocation');
}
