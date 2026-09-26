import 'dart:convert';
import 'dart:io';

import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/hot_reload/dart_vm_service_client.dart';
import 'package:xcross/src/flutter/hot_reload/hot_reload_controller.dart';
import 'package:xcross/src/flutter/models/hot_reload_config.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late HotReloadController controller;
  late File source;
  late File commands;
  late File compileFailure;
  var uploadFailure = false;
  var reloadFailure = false;
  var restartFailure = false;
  var reloads = 0;
  var restarts = 0;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_reload_controller-');
    source = File(p.join(tmp.path, 'lib/main.dart'));
    source.parent.createSync();
    source.writeAsStringSync('void main() {}');
    final config = File(p.join(tmp.path, 'package_config.json'))
      ..writeAsStringSync(
        jsonEncode({'configVersion': 2, 'packages': <Object?>[]}),
      );
    final frontend = File(p.join(tmp.path, 'frontend.dart'))
      ..writeAsStringSync(_frontend);
    commands = File(p.join(tmp.path, 'commands'));
    compileFailure = File(p.join(tmp.path, 'fail'));
    uploadFailure = false;
    reloadFailure = false;
    restartFailure = false;
    reloads = 0;
    restarts = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        await request.drain<void>();
        request.response.statusCode = uploadFailure ? 500 : 200;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        final method = message['method'];
        Object result = <String, Object?>{};
        if (method == '_createDevFS') {
          result = {'uri': 'org-dartlang-devfs://test/'};
        } else if (method == '_flutter.listViews') {
          result = {
            'views': [
              {
                'id': 'view',
                'isolate': {'id': 'isolate'},
              },
            ],
          };
        } else if (method == 'reloadSources') {
          reloads++;
          result = {'success': !reloadFailure};
        } else if (method == '_flutter.runInView') {
          restarts++;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'streamNotify',
              'params': {
                'streamId': 'Isolate',
                'event': {'kind': 'IsolateRunnable'},
              },
            }),
          );
          if (restartFailure) {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': message['id'],
                'error': {'code': -32000, 'message': 'restart failed'},
              }),
            );
            return;
          }
        }
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': message['id'], 'result': result}),
        );
      });
    });
    final vm = DartVmServiceClient();
    await vm.connect(Uri.parse('ws://127.0.0.1:${server.port}/ws'));
    controller = HotReloadController(
      config: HotReloadConfig(
        dart: Platform.resolvedExecutable,
        frontendServer: frontend.path,
        sdkRoot: tmp.path,
        packageConfig: config.path,
        entrypoint: source.path,
        projectRoot: tmp.path,
        outputDill: p.join(tmp.path, 'output.dill'),
      ),
      vm: vm,
      vmService: DeviceEndpoint(host: '127.0.0.1', port: server.port),
    );
  });

  tearDown(() async {
    await controller.close();
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  int commandCount(String command) => commands
      .readAsLinesSync()
      .where((line) => line == command || line.startsWith('$command '))
      .length;

  for (final failure in ['compile', 'upload', 'reload']) {
    test('retries the same edit after $failure failure', () async {
      await controller.initialSync();
      source.writeAsStringSync('void main() { print(1); }');
      if (failure == 'compile') compileFailure.writeAsStringSync('fail');
      uploadFailure = failure == 'upload';
      reloadFailure = failure == 'reload';
      if (failure == 'reload') {
        expect(await controller.reload(), isFalse);
      } else {
        await expectLater(controller.reload(), throwsA(isA<Exception>()));
      }
      if (compileFailure.existsSync()) compileFailure.deleteSync();
      uploadFailure = false;
      reloadFailure = false;
      expect(await controller.reload(), isTrue);
      expect(commandCount('recompile'), 2);
      expect(commandCount('reject'), 1);
      expect(
        commands.readAsLinesSync().where(
          (line) => line == source.uri.toString(),
        ),
        hasLength(2),
      );
      final previousReloads = reloads;
      expect(await controller.reload(), isTrue);
      expect(reloads, previousReloads);
    });
  }

  test('restores deleted source invalidations after rejected reload', () async {
    await controller.initialSync();
    source.deleteSync();
    reloadFailure = true;
    expect(await controller.reload(), isFalse);
    reloadFailure = false;
    expect(await controller.reload(), isTrue);
    expect(commandCount('recompile'), 2);
    expect(commandCount('reject'), 1);
  });

  test(
    'retains edits after failed restart and accepts only on success',
    () async {
      await controller.initialSync();
      source.writeAsStringSync('void main() { print(1); }');
      restartFailure = true;
      await expectLater(controller.restart(), throwsA(isA<Exception>()));
      expect(commandCount('accept'), 1);
      expect(commandCount('reject'), 1);
      restartFailure = false;
      await controller.restart();
      expect(restarts, 2);
      expect(commandCount('recompile'), 2);
      expect(
        commands.readAsLinesSync().where(
          (line) => line == source.uri.toString(),
        ),
        hasLength(2),
      );
    },
  );

  for (final failure in ['compile', 'upload']) {
    test('retries restart invalidations after $failure failure', () async {
      await controller.initialSync();
      source.writeAsStringSync('void main() { print(1); }');
      if (failure == 'compile') compileFailure.writeAsStringSync('fail');
      uploadFailure = failure == 'upload';
      await expectLater(controller.restart(), throwsA(isA<Exception>()));
      if (compileFailure.existsSync()) compileFailure.deleteSync();
      uploadFailure = false;
      await controller.restart();
      expect(commandCount('reject'), 1);
      expect(commandCount('recompile'), 2);
      expect(
        commands.readAsLinesSync().where(
          (line) => line == source.uri.toString(),
        ),
        hasLength(2),
      );
    });
  }

  test('closes a compiler whose rejection acknowledgement fails', () async {
    await controller.initialSync();
    source.writeAsStringSync('void main() { print(1); }');
    File(p.join(tmp.path, 'reject-fail')).writeAsStringSync('fail');
    reloadFailure = true;
    await expectLater(controller.reload(), throwsA(isA<Exception>()));
    reloadFailure = false;
    await expectLater(controller.reload(), throwsA(isA<Exception>()));
    expect(commandCount('recompile'), 1);
  });

  test('initial compilation errors propagate without accepting', () async {
    compileFailure.writeAsStringSync('fail');
    await expectLater(controller.initialSync(), throwsA(isA<Exception>()));
    expect(commandCount('accept'), 0);
    expect(commandCount('reject'), 1);
  });
}

const _frontend = r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final output = File(args[args.indexOf('--output-dill') + 1]);
  final commands = File('${output.parent.path}/commands');
  final failure = File('${output.parent.path}/fail');
  String? boundary;
  void result() {
    output.writeAsStringSync('kernel');
    stdout.writeln('result response');
    stdout.writeln('response ${output.path} ${failure.existsSync() ? 1 : 0}');
  }
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    commands.writeAsStringSync('$line\n', mode: FileMode.append);
    if (boundary != null) {
      if (line == boundary) {
        boundary = null;
        result();
      }
    } else if (line.startsWith('compile ')) {
      result();
    } else if (line.startsWith('recompile ')) {
      boundary = line.split(' ').last;
    } else if (line == 'reject') {
      if (File('${output.parent.path}/reject-fail').existsSync()) return;
      stdout.writeln('result rejected');
      stdout.writeln('rejected');
    } else if (line == 'quit') {
      return;
    }
  }
}
''';
