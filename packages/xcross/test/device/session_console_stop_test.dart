import 'dart:async';
import 'dart:io';

import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:test/test.dart';
import 'package:xcross/src/device/core_device_launcher.dart';
import 'package:xcross/src/device/session_console.dart';

void main() {
  test('failed initial resume stops and awaits the console', () async {
    final gdb = GdbRemoteClient(host: '127.0.0.1', port: 1);
    addTearDown(gdb.close);
    final console = SessionConsole(
      gdb: gdb,
      hotReload: null,
      listenForKeyboard: false,
    );
    final running = console.run();

    await expectLater(
      CoreDeviceLauncher.resumeInitialDebugger(
        console: console,
        consoleFuture: running,
        resume: () async => throw StateError('resume failed'),
      ),
      throwsStateError,
    );
    expect(console.isStopped, isTrue);
    await running.timeout(const Duration(seconds: 2));
    console.stop();
  });

  test('continues after a nonfatal debugserver stop', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final connected = Completer<Socket>();
    server.listen(connected.complete);

    final gdb = GdbRemoteClient(host: '127.0.0.1', port: server.port);
    await gdb.connect();
    addTearDown(gdb.close);
    final socket = await connected.future;

    final continued = Completer<void>();
    final stopSeen = Completer<void>();
    final received = StringBuffer();
    socket.listen((bytes) {
      received.write(String.fromCharCodes(bytes));
      if (received.toString().contains(r'$c#63')) {
        continued.complete();
      }
    });
    gdb.replies.listen((packet) {
      if (packet.payload.startsWith('T05')) stopSeen.complete();
    });

    final console = SessionConsole(
      gdb: gdb,
      hotReload: null,
      listenForKeyboard: false,
    );
    final run = console.run();
    await Future<void>.delayed(Duration.zero);
    socket.add(_frame('T05thread:1;').codeUnits);
    await socket.flush();

    await stopSeen.future.timeout(const Duration(seconds: 2));
    await continued.future.timeout(const Duration(seconds: 2));
    socket.add(_frame('W00').codeUnits);
    await socket.flush();
    await run.timeout(const Duration(seconds: 2));
  });

  test('does not continue a Mach memory fault', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final accepted = server.first;
    final gdb = GdbRemoteClient(host: '127.0.0.1', port: server.port);
    await gdb.connect();
    addTearDown(gdb.close);
    final socket = await accepted;
    addTearDown(socket.destroy);
    final received = StringBuffer();
    socket.listen((bytes) => received.write(String.fromCharCodes(bytes)));
    final console = SessionConsole(
      gdb: gdb,
      hotReload: null,
      listenForKeyboard: false,
    );
    final run = console.run();
    socket.add(
      _frame('T91thread:1;metype:1;mecount:2;medata:1;medata:0;').codeUnits,
    );
    await socket.flush();
    await run.timeout(const Duration(seconds: 2));
    expect(console.isStopped, isTrue);
    expect(received.toString(), isNot(contains(r'$c#63')));
  });

  test('does not continue named or unknown SIGTRAP stops', () async {
    for (final detail in [
      'reason:breakpoint;',
      'reason:watchpoint;',
      'reason:unknown;',
      'watch:100;',
      'rwatch:100;',
      'awatch:100;',
      'swbreak:;',
      'hwbreak:;',
    ]) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final gdb = GdbRemoteClient(host: '127.0.0.1', port: server.port);
      await gdb.connect();
      final socket = await accepted;
      final received = StringBuffer();
      socket.listen((bytes) => received.write(String.fromCharCodes(bytes)));
      final console = SessionConsole(
        gdb: gdb,
        hotReload: null,
        listenForKeyboard: false,
      );
      final run = console.run();
      socket.add(_frame('T05thread:1;$detail').codeUnits);
      await socket.flush();
      await run.timeout(const Duration(seconds: 2));
      expect(console.isStopped, isTrue);
      expect(received.toString(), isNot(contains(r'$c#63')));
      await gdb.close();
      socket.destroy();
      await server.close();
    }
  });

  test(
    'reports a repeated SIGTRAP without sending a second continue',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = server.first;
      final gdb = GdbRemoteClient(host: '127.0.0.1', port: server.port);
      await gdb.connect();
      addTearDown(gdb.close);
      final socket = await accepted;
      addTearDown(socket.destroy);
      final received = StringBuffer();
      final firstContinue = Completer<void>();
      socket.listen((bytes) {
        received.write(String.fromCharCodes(bytes));
        if (!firstContinue.isCompleted &&
            received.toString().contains(r'$c#63')) {
          firstContinue.complete();
        }
      });
      final console = SessionConsole(
        gdb: gdb,
        hotReload: null,
        listenForKeyboard: false,
      );
      final run = console.run();
      socket.add(_frame('T05thread:1;pc:100;').codeUnits);
      await socket.flush();
      await firstContinue.future.timeout(const Duration(seconds: 2));
      socket.add(_frame('T05thread:1;pc:100;').codeUnits);
      await socket.flush();
      await run.timeout(const Duration(seconds: 2));
      expect(console.isStopped, isTrue);
      expect(RegExp(r'\$c#63').allMatches(received.toString()), hasLength(1));
    },
  );

  test('does not resume a second bare SIGTRAP at another PC', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final accepted = server.first;
    final gdb = GdbRemoteClient(host: '127.0.0.1', port: server.port);
    await gdb.connect();
    addTearDown(gdb.close);
    final socket = await accepted;
    addTearDown(socket.destroy);
    final received = StringBuffer();
    final firstContinue = Completer<void>();
    socket.listen((bytes) {
      received.write(String.fromCharCodes(bytes));
      if (!firstContinue.isCompleted &&
          received.toString().contains(r'$c#63')) {
        firstContinue.complete();
      }
    });
    final console = SessionConsole(
      gdb: gdb,
      hotReload: null,
      listenForKeyboard: false,
    );
    final running = console.run();
    socket.add(_frame('T05thread:1;pc:100;').codeUnits);
    await socket.flush();
    await firstContinue.future.timeout(const Duration(seconds: 2));
    socket.add(_frame('T05thread:1;pc:200;').codeUnits);
    await socket.flush();
    await running.timeout(const Duration(seconds: 2));
    expect(RegExp(r'\$c#63').allMatches(received.toString()), hasLength(1));
  });
}

String _frame(String payload) {
  final sum = payload.codeUnits.fold(0, (total, byte) => total + byte) & 0xff;
  return '\$$payload#${sum.toRadixString(16).padLeft(2, '0')}';
}
