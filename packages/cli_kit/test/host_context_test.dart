import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_log_output.dart';
import 'support/test_process_io.dart';

void main() {
  final io = TestProcessIo();
  tearDownAll(io.close);
  final log = Log(output: TestLogOutput(emit: print));
  final constructors = <PlatformHostInterface Function(String)>[
    (root) => LinuxHost(currentDirectory: root, environment: {'PATH': '.'}),
    (root) => MacOSHost(currentDirectory: root, environment: {'PATH': '.'}),
  ];

  test(
    'relative filesystem operations stay within independent host contexts',
    () async {
      final temp = Directory.systemTemp.createTempSync('host-context-');
      addTearDown(() => temp.deleteSync(recursive: true));
      for (var index = 0; index < constructors.length; index++) {
        final firstRoot = Directory(p.join(temp.path, '$index-first'))
          ..createSync();
        final secondRoot = Directory(p.join(temp.path, '$index-second'))
          ..createSync();
        final first = constructors[index](firstRoot.path);
        final second = constructors[index](secondRoot.path);
        first.fileSystem.file('value').writeAsStringSync('first');
        second.fileSystem.file('value').writeAsStringSync('second');
        expect(first.fileSystem.file('value').readAsStringSync(), 'first');
        expect(second.fileSystem.file('value').readAsStringSync(), 'second');
        expect(
          first.fileSystem.file('value').path,
          first.paths.pathKey('value'),
        );
        first.fileSystem.directory('sub').createSync();
        expect(Directory(p.join(firstRoot.path, 'sub')).existsSync(), isTrue);
        expect(Directory(p.join(secondRoot.path, 'sub')).existsSync(), isFalse);
        await first.fileSystem.createArchiveLink('relative-link', 'value');
        expect(first.fileSystem.link('relative-link').targetSync(), 'value');
        expect(
          first.fileSystem.file('relative-link').readAsStringSync(),
          'first',
        );
        expect(second.fileSystem.link('relative-link').existsSync(), isFalse);
      }
    },
    skip: Platform.isWindows ? 'POSIX symlink semantics' : false,
  );

  test(
    'default child cwd and shell lookup use the selected snapshot',
    () async {
      final temp = Directory.systemTemp.createTempSync('host-child-context-');
      addTearDown(() => temp.deleteSync(recursive: true));
      for (var index = 0; index < constructors.length; index++) {
        final firstRoot = Directory(p.join(temp.path, '$index-first'))
          ..createSync();
        final secondRoot = Directory(p.join(temp.path, '$index-second'))
          ..createSync();
        final first = constructors[index](firstRoot.path);
        final second = constructors[index](secondRoot.path);
        ProcessRunner<PlatformHostInterface> runner(
          PlatformHostInterface host,
        ) => ProcessRunner(
          host,
          log: log,
          stdinStream: io.input,
          stdoutSink: io.output,
          stderrSink: io.error,
        );
        final firstRunner = runner(first);
        final secondRunner = runner(second);
        expect(
          (await firstRunner.run('/bin/pwd', [])).stdout.trim(),
          firstRoot.resolveSymbolicLinksSync(),
        );
        expect(
          (await secondRunner.run('/bin/pwd', [])).stdout.trim(),
          secondRoot.resolveSymbolicLinksSync(),
        );
        final sub = first.fileSystem.directory('sub')..createSync();
        expect(
          (await firstRunner.run(
            '/bin/pwd',
            [],
            workingDirectory: 'sub',
          )).stdout.trim(),
          sub.resolveSymbolicLinksSync(),
        );
        expect(
          (await firstRunner.run(
            '/bin/pwd',
            [],
            workingDirectory: secondRoot.path,
          )).stdout.trim(),
          secondRoot.resolveSymbolicLinksSync(),
        );
        first.fileSystem
            .file('only-first')
            .writeAsStringSync('#!/bin/sh\nexit 0\n');
        second.fileSystem
            .file('only-second')
            .writeAsStringSync('#!/bin/sh\nexit 0\n');
        first.fileSystem.makeExecutable('only-first');
        second.fileSystem.makeExecutable('only-second');
        expect(
          await first.processes.findOnShellPath(
            'only-first',
            environment: first.environment.values,
            includeParentEnvironment: false,
          ),
          predicate<String>(
            (value) =>
                first.paths.pathKey(value) == first.paths.pathKey('only-first'),
          ),
        );
        expect(
          await second.processes.findOnShellPath(
            'only-first',
            environment: second.environment.values,
            includeParentEnvironment: false,
          ),
          isNull,
        );
        expect(
          await second.processes.findOnShellPath(
            'only-second',
            environment: second.environment.values,
            includeParentEnvironment: false,
          ),
          predicate<String>(
            (value) =>
                second.paths.pathKey(value) ==
                second.paths.pathKey('only-second'),
          ),
        );
        final child = await first.processes.start(
          '/bin/pwd',
          [],
          includeParentEnvironment: false,
        );
        final output = child.stdout.transform(utf8.decoder).join();
        await child.stderr.drain<void>();
        expect((await output).trim(), firstRoot.resolveSymbolicLinksSync());
        expect(await child.exitCode, 0);
      }
    },
    skip: Platform.isWindows ? 'POSIX native process semantics' : false,
  );
}
