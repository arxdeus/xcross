@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/windows/flutter/windows_flutter_sdk_policy.dart';

import '../flutter_test_log.dart';

void main() {
  test(
    'Windows shim SDK strategy resolves mise rather than the shims directory',
    () async {
      final root = Directory.systemTemp.createTempSync('xcross_windows_mise_');
      addTearDown(() => root.deleteSync(recursive: true));
      final sdk = Directory(p.join(root.path, 'selected-sdk'))..createSync();
      Directory(p.join(sdk.path, 'bin')).createSync();
      final mise = File(p.join(root.path, 'mise'))
        ..writeAsStringSync("#!/bin/sh\nprintf '%s\\n' '${sdk.path}'\n");
      final native = LinuxHost(
        currentDirectory: root.path,
        temporaryDirectory: root.path,
      );
      native.fileSystem.makeExecutable(mise.path);
      final host = WindowsHost(
        paths: native.paths,
        fileSystem: native.fileSystem,
        processes: native.processes,
      );
      final runner = ProcessRunner(
        host,
        log: testFlutterLog(),
        stdinStream: const Stream<List<int>>.empty(),
        stdoutSink: stdout,
        stderrSink: stderr,
        configuration: ProcessConfiguration(
          normalizedTools: {'mise': mise.path},
          effectiveChildEnvironment: const {},
        ),
      );
      final policy = WindowsFlutterSdkPolicy<WindowsHost>();
      final shim = p.join(root.path, 'shims', 'flutter.bat');
      expect(await policy.rootFromExecutable(shim, runner), sdk.path);
      expect(
        await policy.rootFromExecutable(
          p.join(sdk.path, 'bin', 'flutter.bat'),
          runner,
        ),
        sdk.path,
      );
    },
  );
}
