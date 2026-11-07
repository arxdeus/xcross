import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/build/internal/staged_directory_swap.dart';

import '../../apple/support/native_test_file_system.dart';

void main() {
  StagedDirectorySwap swapper({DirectoryRenamer? rename}) =>
      StagedDirectorySwap(
        fileSystem: const NativeTestFileSystem(),
        paths: p.context,
        copier: RecursiveDirectoryCopier(
          fileSystem: const NativeTestFileSystem(),
          paths: p.context,
        ),
        rename: rename,
        retryDelays: const [Duration.zero, Duration.zero],
      );

  late Directory root;
  late String dest;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('xcross_swap-');
    dest = p.join(root.path, 'out', 'Runner.app');
  });
  tearDown(() => root.delete(recursive: true));

  Future<Directory> stageWith(StagedDirectorySwap swap, String content) async {
    final staging = await swap.createStaging(dest);
    expect(p.basename(staging.path), 'Runner.app');
    expect(p.dirname(p.dirname(staging.path)), p.dirname(dest));
    await staging.create();
    await File(p.join(staging.path, 'Info.plist')).writeAsString(content);
    return staging;
  }

  List<String> siblings() => Directory(
    p.dirname(dest),
  ).listSync().map((e) => p.basename(e.path)).toList()..sort();

  test('destination missing: staging is renamed into place', () async {
    final swap = swapper();
    await swap.swap(await stageWith(swap, 'new'), dest);
    expect(File(p.join(dest, 'Info.plist')).readAsStringSync(), 'new');
    expect(siblings(), ['Runner.app']);
  });

  test('destination exists: it is replaced, old contents gone', () async {
    await Directory(dest).create(recursive: true);
    await File(p.join(dest, 'stale.txt')).writeAsString('x');
    final swap = swapper();
    await swap.swap(await stageWith(swap, 'new'), dest);
    expect(File(p.join(dest, 'stale.txt')).existsSync(), isFalse);
    expect(File(p.join(dest, 'Info.plist')).readAsStringSync(), 'new');
    expect(siblings(), ['Runner.app']);
  });

  test(
    'stale staging and backup dirs from a crashed run are removed',
    () async {
      final out = p.dirname(dest);
      await Directory(
        p.join(out, '.Runner.app.staging-dead'),
      ).create(recursive: true);
      await Directory(
        p.join(out, '.Runner.app.old-dead'),
      ).create(recursive: true);
      await Directory(
        p.join(out, '.Other.app.staging-keep'),
      ).create(recursive: true);
      final swap = swapper();
      await swap.swap(await stageWith(swap, 'new'), dest);
      expect(siblings(), ['.Other.app.staging-keep', 'Runner.app']);
    },
  );

  test('rename retries, then succeeds', () async {
    var calls = 0;
    final swap = swapper(
      rename: (source, target) async {
        if (++calls == 1) throw const FileSystemException('locked');
        await source.rename(target);
      },
    );
    await swap.swap(await stageWith(swap, 'new'), dest);
    expect(calls, 2);
    expect(siblings(), ['Runner.app']);
  });

  test('persistent rename failure falls back to copy and delete', () async {
    await Directory(dest).create(recursive: true);
    await File(p.join(dest, 'stale.txt')).writeAsString('x');
    final swap = swapper(
      rename: (_, _) async => throw const FileSystemException('locked'),
    );
    await swap.swap(await stageWith(swap, 'new'), dest);
    expect(File(p.join(dest, 'stale.txt')).existsSync(), isFalse);
    expect(File(p.join(dest, 'Info.plist')).readAsStringSync(), 'new');
    expect(siblings(), ['Runner.app']);
  });

  test('discard removes the staging container', () async {
    final swap = swapper();
    await swap.discard(await stageWith(swap, 'new'));
    expect(siblings(), isEmpty);
  });
}
