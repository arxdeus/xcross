import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/cache/cache_pruner.dart';
import 'package:xcross/src/shared/cli/basic/cache_command.dart';

import '../log_fixture.dart';

final _engineA = 'a' * 40;
final _engineB = 'b' * 40;
final _engineC = 'c' * 40;

void main() {
  late Directory root;
  late String engineRoot;
  late String genRoot;
  final now = DateTime.utc(2026, 10, 9);

  setUp(() {
    root = Directory.systemTemp.createTempSync('xcross-prune-');
    engineRoot = p.join(root.path, 'flutter-engine');
    genRoot = p.join(root.path, 'gen-snapshot');
  });
  tearDown(() => root.deleteSync(recursive: true));

  void engineEntry(String engine, DateTime lastUsed, {int size = 10}) {
    final dir = Directory(p.join(engineRoot, engine, 'artifacts', 'engine'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'blob')).writeAsBytesSync(List.filled(size, 1));
    File(
      p.join(engineRoot, engine, '.last_used'),
    ).writeAsStringSync(lastUsed.toIso8601String());
  }

  void genEntry(String engine, DateTime lastUsed, {int size = 10}) {
    final dir = Directory(p.join(genRoot, engine, 'release', 'linux-x64'))
      ..createSync(recursive: true);
    File(
      p.join(dir.path, 'gen_snapshot'),
    ).writeAsBytesSync(List.filled(size, 2));
    File(p.join(dir.path, 'meta.json')).writeAsStringSync(
      jsonEncode({'engine': engine, 'last_used': lastUsed.toIso8601String()}),
    );
  }

  CachePruner pruner({Set<String> inUse = const {}, int days = 30}) =>
      CachePruner(
        LinuxHost(),
        engineRoot: engineRoot,
        genSnapshotRoot: genRoot,
        inUseEngines: inUse,
        olderThan: Duration(days: days),
        now: () => now,
      );

  group('CachePruner', () {
    test('removes old entries for engines no SDK uses', () async {
      engineEntry(_engineA, now.subtract(const Duration(days: 90)), size: 100);
      genEntry(_engineA, now.subtract(const Duration(days: 90)), size: 50);
      final result = await pruner().prune();
      expect(result.removed.map((e) => e.kind).toSet(), {
        'flutter-engine',
        'gen-snapshot',
      });
      expect(result.freedBytes, greaterThanOrEqualTo(150));
      expect(Directory(p.join(engineRoot, _engineA)).existsSync(), isFalse);
      expect(Directory(p.join(genRoot, _engineA)).existsSync(), isFalse);
    });

    test('keeps engines a discovered Flutter SDK uses, however old', () async {
      engineEntry(_engineA, now.subtract(const Duration(days: 400)));
      final result = await pruner(inUse: {_engineA}).prune();
      expect(result.removed, isEmpty);
      expect(Directory(p.join(engineRoot, _engineA)).existsSync(), isTrue);
    });

    test('keeps recently used entries for unknown engines', () async {
      genEntry(_engineB, now.subtract(const Duration(days: 3)));
      final result = await pruner().prune();
      expect(result.removed, isEmpty);
      expect(result.kept.single.engine, _engineB);
    });

    test('dry run reports without deleting', () async {
      engineEntry(_engineC, now.subtract(const Duration(days: 90)));
      final result = await pruner().prune(dryRun: true);
      expect(result.removed.single.engine, _engineC);
      expect(Directory(p.join(engineRoot, _engineC)).existsSync(), isTrue);
    });

    test('ignores directories that are not engine revisions', () {
      Directory(p.join(genRoot, '.download-123')).createSync(recursive: true);
      Directory(p.join(engineRoot, 'notes')).createSync(recursive: true);
      final entries = pruner(days: 0).scan();
      expect(entries, isEmpty);
    });

    test('a missing cache is simply empty', () async {
      final result = await pruner().prune();
      expect(result.removed, isEmpty);
      expect(result.kept, isEmpty);
    });
  });

  group('xcross cache prune', () {
    Future<List<String>> run(
      List<String> args, {
      Set<String> inUse = const {},
    }) async {
      final output = TestLogOutput();
      final command = CachePruneCommand(
        host: LinuxHost(),
        log: Log(output: output),
        engineRoot: engineRoot,
        genSnapshotRoot: genRoot,
        inUseEngines: () async => inUse,
        now: () => now,
      );
      final runner = CommandRunner<void>('xcross', 'test')
        ..addCommand(CacheCommand(command));
      await runner.run(['cache', 'prune', ...args]);
      return output.messages;
    }

    test('reports what it freed', () async {
      engineEntry(_engineA, now.subtract(const Duration(days: 90)), size: 2048);
      final lines = await run([], inUse: {_engineB});
      expect(lines, contains(contains('Removed flutter-engine aaaaaaaa')));
      expect(lines, contains(contains('Freed 2.0 KB')));
    });

    test('--dry-run leaves files and says so', () async {
      engineEntry(_engineA, now.subtract(const Duration(days: 90)));
      final lines = await run(['--dry-run'], inUse: {_engineB});
      expect(lines, contains(contains('Would remove')));
      expect(Directory(p.join(engineRoot, _engineA)).existsSync(), isTrue);
    });

    test('--older-than narrows what counts as stale', () async {
      engineEntry(_engineA, now.subtract(const Duration(days: 10)));
      expect(
        await run(['--older-than', '30'], inUse: {_engineB}),
        contains(contains('Nothing to prune')),
      );
      await run(['--older-than', '7'], inUse: {_engineB});
      expect(Directory(p.join(engineRoot, _engineA)).existsSync(), isFalse);
    });

    test('warns when no Flutter SDK could be found', () async {
      final lines = await run([]);
      expect(lines, contains(contains('No Flutter SDK was found')));
    });

    test('rejects a malformed --older-than', () async {
      await expectLater(
        run(['--older-than', 'soon']),
        throwsA(isA<UsageException>()),
      );
    });
  });

  test('formatBytes', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(300 * 1024 * 1024), '300 MB');
  });

  test('flutterEngineRevision reads engine.version', () {
    final sdk = Directory(p.join(root.path, 'flutter', 'bin', 'internal'))
      ..createSync(recursive: true);
    File(p.join(sdk.path, 'engine.version')).writeAsStringSync('$_engineA\n');
    expect(
      flutterEngineRevision(LinuxHost(), p.join(root.path, 'flutter')),
      _engineA,
    );
    expect(flutterEngineRevision(LinuxHost(), root.path), isNull);
  });
}
