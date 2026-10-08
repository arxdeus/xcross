import 'dart:io';

import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/host/windows/windows_paths.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';
import 'package:xcross/src/shared/flutter/build/internal/flutter_tool_workspace.dart';
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';

import 'support/native_flutter_fixtures.dart';

void main() {
  test(
    'POSIX simulation isolates host policies and canonical Flutter cache paths',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'flutter_workspace_hosts-',
      );
      try {
        final roots = <String>{};
        final iosFrameworks = <String>{};
        final flutterRoot = p.join(tmp.resolveSymbolicLinksSync(), 'sdk');
        Directory(p.join(flutterRoot, 'packages')).createSync(recursive: true);
        final sdkCache = Directory(p.join(flutterRoot, 'bin', 'cache'))
          ..createSync(recursive: true);
        File(p.join(flutterRoot, 'bin', 'internal', 'engine.version'))
          ..createSync(recursive: true)
          ..writeAsStringSync('engine-hash');
        Directory(p.join(sdkCache.path, 'dart-sdk')).createSync();
        File(
          p.join(sdkCache.path, 'flutter_tools.snapshot'),
        ).writeAsStringSync('snapshot');
        for (final (abi, hostTools, targetPolicy) in nativeHostCases()) {
          final cache = IosEngineCache(
            targetPolicy: targetPolicy,
            hostTools: hostTools,
            flutterRoot: flutterRoot,
            cacheRoot: p.join(tmp.path, 'cache'),
            log: nativeTestLog(),
            downloader: nativeTestDownloader(),
          );
          Directory(cache.flutterXcframework).createSync(recursive: true);
          iosFrameworks.add(cache.flutterXcframework);
          Directory(cache.patchedSdkRoot).createSync(recursive: true);
          File(cache.vmSnapshotData)
            ..createSync(recursive: true)
            ..writeAsStringSync(abi);
          File(cache.isolateSnapshotData).writeAsStringSync(abi);
          final workspace = await FlutterToolWorkspace.create(
            flutterRoot: flutterRoot,
            engineCache: cache,
          );
          roots.add(workspace.flutterRoot);
          expect(workspace.dart, startsWith(flutterRoot));
          expect(workspace.flutterToolsSnapshot, startsWith(flutterRoot));
          final engine = p.join(
            workspace.flutterRoot,
            'bin',
            'cache',
            'artifacts',
            'engine',
          );
          expect(
            File(
              p.join(
                engine,
                cache.hostEngineCacheDirectory,
                'vm_isolate_snapshot.bin',
              ),
            ).readAsStringSync(),
            abi,
          );
          expect(
            Directory(
              p.join(engine, 'ios', 'Flutter.xcframework'),
            ).existsSync(),
            isTrue,
          );
          if (cache.hostArtifactPlatform == 'darwin-arm64') {
            expect(
              Directory(p.join(engine, 'darwin-arm64')).existsSync(),
              isFalse,
            );
          }
        }
        expect(roots, hasLength(5));
        expect(iosFrameworks, hasLength(1));
      } finally {
        await tmp.delete(recursive: true);
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'Windows native tools create directory junctions and file links',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'native_windows_links-',
      );
      try {
        final host = WindowsHost(
          architecture: 'x64',
          environment: Platform.environment,
        );
        final tools = WindowsNativeHostTools(
          host,
          ProcessRunner(
            host,
            log: nativeTestLog(),
            stdinStream: const Stream<List<int>>.empty(),
            stdoutSink: nativeTestSink(),
            stderrSink: nativeTestSink(),
          ),
        );
        final source = Directory(p.join(temp.path, 'source'))..createSync();
        final file = File(p.join(source.path, 'payload'))
          ..writeAsStringSync('payload');
        final directoryLink = p.join(temp.path, 'directory-link');
        final fileLink = p.join(temp.path, 'file-link');
        await tools.link(directoryLink, source.path);
        await tools.link(fileLink, file.path);
        expect(
          File(p.join(directoryLink, 'payload')).readAsStringSync(),
          'payload',
        );
        expect(File(fileLink).readAsStringSync(), 'payload');
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  test('Windows native tools pass long-path link operands to mklink', () async {
    final processes = LinkRecordingProcesses();
    final host = WindowsHost(
      architecture: 'arm64',
      paths: WindowsPaths(currentDirectory: r'C:\work'),
      processes: processes,
      environment: const {'PATH': '', 'PATHEXT': '.EXE'},
    );
    final tools = WindowsNativeHostTools(
      host,
      ProcessRunner(
        host,
        log: nativeTestLog(),
        stdinStream: const Stream<List<int>>.empty(),
        stdoutSink: nativeTestSink(),
        stderrSink: nativeTestSink(),
      ),
    );
    final deep = [r'C:\root', for (var i = 0; i < 30; i++) 'segment$i'];
    final path = '${deep.join(r'\')}\\entry';
    await tools.link(path, r'C:\source\entry');
    expect(processes.arguments.single, [
      '/c',
      'mklink',
      '/H',
      '\\\\?\\$path',
      r'\\?\C:\source\entry',
    ]);
  });

  test('keeps the workspace root one short key below the cache root', () async {
    final tmp = await Directory.systemTemp.createTemp('workspace_depth-');
    try {
      final cacheRoot = p.join(tmp.path, 'cache');
      final cache = workspaceSdk(p.join(tmp.path, 'sdk'), cacheRoot, 'sdk');
      final workspace = await FlutterToolWorkspace.create(
        flutterRoot: cache.flutterRoot,
        engineCache: cache,
      );
      final segments = p.split(
        p.relative(workspace.flutterRoot, from: cacheRoot),
      );
      expect(segments, hasLength(2));
      expect(segments.first, 'workspaces');
      expect(segments.last, hasLength(FlutterToolWorkspace.workspaceKeyLength));
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  for (final removeOldRoot in [false, true]) {
    test(
      'isolates same-engine SDK roots with old root removed: $removeOldRoot',
      () async {
        final tmp = await Directory.systemTemp.createTemp('workspace_sources-');
        try {
          final cacheRoot = p.join(tmp.path, 'cache');
          final firstCache = workspaceSdk(
            p.join(tmp.path, 'sdk-a'),
            cacheRoot,
            'sdk-a',
          );
          final secondCache = workspaceSdk(
            p.join(tmp.path, 'sdk-b'),
            cacheRoot,
            'sdk-b',
          );
          final first = await FlutterToolWorkspace.create(
            flutterRoot: firstCache.flutterRoot,
            engineCache: firstCache,
          );
          if (removeOldRoot) {
            await Directory(firstCache.flutterRoot).delete(recursive: true);
          }
          final second = await FlutterToolWorkspace.create(
            flutterRoot: secondCache.flutterRoot,
            engineCache: secondCache,
          );

          expectWorkspaceSdk(second, 'sdk-b');
          expect(second.flutterRoot, isNot(first.flutterRoot));
          expect(Directory(first.flutterRoot).existsSync(), isTrue);
          final secondRoot = Directory(
            secondCache.flutterRoot,
          ).resolveSymbolicLinksSync();
          expect(second.dart, startsWith(secondRoot));
          expect(second.flutterToolsSnapshot, startsWith(secondRoot));
        } finally {
          await tmp.delete(recursive: true);
        }
      },
    );
  }

  test(
    'reuses a canonical SDK root through relative paths and aliases',
    () async {
      final tmp = await Directory.systemTemp.createTemp('workspace_alias-');
      try {
        final cache = workspaceSdk(
          p.join(tmp.path, 'sdk'),
          p.join(tmp.path, 'cache'),
          'sdk',
        );
        final first = await FlutterToolWorkspace.create(
          flutterRoot: p.relative(cache.flutterRoot),
          engineCache: cache,
        );
        final sentinel = File(p.join(first.flutterRoot, 'retained'))
          ..writeAsStringSync('retained');
        final alias = Link(p.join(tmp.path, 'alias'))
          ..createSync(cache.flutterRoot);
        final second = await FlutterToolWorkspace.create(
          flutterRoot: alias.path,
          engineCache: nativeLinuxEngineCache(
            flutterRoot: alias.path,
            cacheRoot: cache.cacheRoot,
          ),
        );

        expect(second.flutterRoot, first.flutterRoot);
        expect(sentinel.readAsStringSync(), 'retained');
        expectWorkspaceSdk(second, 'sdk');
      } finally {
        await tmp.delete(recursive: true);
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'pins SDK-local engine artifacts and tools across alias changes',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'workspace_local_alias-',
      );
      try {
        final cacheRoot = p.join(tmp.path, 'cache');
        final firstCache = workspaceSdk(
          p.join(tmp.path, 'sdk-a'),
          cacheRoot,
          'sdk-a',
          sdkLocalEngine: true,
        );
        final secondCache = workspaceSdk(
          p.join(tmp.path, 'sdk-b'),
          cacheRoot,
          'sdk-b',
          sdkLocalEngine: true,
        );
        final alias = Link(p.join(tmp.path, 'alias'))
          ..createSync(firstCache.flutterRoot);
        final workspace = await FlutterToolWorkspace.create(
          flutterRoot: alias.path,
          engineCache: nativeLinuxEngineCache(
            flutterRoot: alias.path,
            cacheRoot: cacheRoot,
          ),
        );
        final sentinel = File(p.join(workspace.flutterRoot, 'retained'))
          ..writeAsStringSync('retained');
        final engine = p.join(
          workspace.flutterRoot,
          'bin',
          'cache',
          'artifacts',
          'engine',
        );
        void expectFirstSdk() {
          expectWorkspaceSdk(workspace, 'sdk-a');
          expect(
            File(workspace.flutterToolsSnapshot).readAsStringSync(),
            'sdk-a',
          );
          expect(File(workspace.dart).readAsStringSync(), 'sdk-a');
          for (final relative in [
            p.join('ios', 'Flutter.xcframework', 'source'),
            p.join('linux-arm64', 'vm_isolate_snapshot.bin'),
            p.join('common', 'flutter_patched_sdk', 'source'),
          ]) {
            expect(File(p.join(engine, relative)).readAsStringSync(), 'sdk-a');
          }
        }

        expectFirstSdk();
        await alias.delete();
        await alias.create(secondCache.flutterRoot);
        expectFirstSdk();
        await alias.delete();
        expectFirstSdk();

        final reused = await FlutterToolWorkspace.create(
          flutterRoot: firstCache.flutterRoot,
          engineCache: firstCache,
        );
        expect(reused.flutterRoot, workspace.flutterRoot);
        expect(sentinel.readAsStringSync(), 'retained');
        expectFirstSdk();
      } finally {
        await tmp.delete(recursive: true);
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'launches relative SDK tools from a different project directory',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'workspace_launch_cwd-',
      );
      try {
        final cache = workspaceSdk(
          p.join(tmp.path, 'sdk'),
          p.join(tmp.path, 'cache'),
          'sdk',
        );
        final dart =
            File(
                p.join(
                  cache.flutterRoot,
                  'bin',
                  'cache',
                  'dart-sdk',
                  'bin',
                  'dart',
                ),
              )
              ..createSync(recursive: true)
              ..writeAsStringSync('#!/bin/sh\ncat "\$1"\n');
        final chmod = await Process.run('/bin/chmod', ['+x', dart.path]);
        expect(chmod.exitCode, 0);
        final project = Directory(p.join(tmp.path, 'project'))..createSync();
        final relativeRoot = p.relative(cache.flutterRoot);
        final first = await FlutterToolWorkspace.create(
          flutterRoot: relativeRoot,
          engineCache: cache,
        );
        final second = await FlutterToolWorkspace.create(
          flutterRoot: relativeRoot,
          engineCache: cache,
        );
        for (final workspace in [first, second]) {
          expect(p.isAbsolute(workspace.dart), isTrue);
          expect(p.isAbsolute(workspace.flutterToolsSnapshot), isTrue);
          final result = await Process.run(workspace.dart, [
            workspace.flutterToolsSnapshot,
          ], workingDirectory: project.path);
          expect(result.exitCode, 0, reason: '${result.stderr}');
          expect(result.stdout, 'sdk');
        }
      } finally {
        await tmp.delete(recursive: true);
      }
    },
    skip: Platform.isWindows,
  );
}
