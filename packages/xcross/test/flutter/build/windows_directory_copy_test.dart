import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/windows_swift_plan_repair.dart';
import 'swiftpm_test_context.dart';

void main() {
  final windows = testWindowsSwiftPmRuntime();
  final posix = testSwiftPmRuntime();
  final repairs = WindowsSwiftPlanRepair(windows.runner);
  String plan(String source, {String kind = 'directory'}) => jsonEncode({
    'copyCommands': {
      'framework-copy': {
        'inputs': [
          {'kind': kind, 'name': source},
        ],
        'outputs': [
          {'kind': 'directory', 'name': r'D:\build\Example.framework'},
        ],
      },
    },
    'unrelated': source,
  });

  test(
    'normalizes extended drive directory sources without changing nodes',
    () {
      final source = '${r'\\?\e:\'}${r'nested\' * 20}Example.framework';
      final original = plan(source);
      final result = repairs.normalizeWindowsDirectoryCopyInputs(original);
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      final commands = decoded['copyCommands'] as Map<String, dynamic>;
      final command = commands['framework-copy'] as Map<String, dynamic>;
      expect((command['inputs'] as List<dynamic>).single, {
        'kind': 'directory',
        'name': source.substring(4),
      });
      expect((command['outputs'] as List<dynamic>).single, {
        'kind': 'directory',
        'name': r'D:\build\Example.framework',
      });
      expect(decoded['unrelated'], source);
      expect(repairs.normalizeWindowsDirectoryCopyInputs(result), result);
    },
  );

  test('retains extended paths when the source exceeds MAX_PATH', () {
    final source = '${r'\\?\e:\'}${r'nested\' * 50}Example.framework';
    final original = plan(source);
    expect(repairs.normalizeWindowsDirectoryCopyInputs(original), original);
  });

  test(
    'stages a long Windows directory copy through a verified junction',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        "xcross&%TEMP%'[copy]-long-",
      );
      var source = p.join(scratch.path, 'vendor');
      while (source.length < 265) {
        source = p.join(source, 'nested-framework-source');
      }
      final extendedSource = r'\\?\' + source;
      final directory = await Directory(extendedSource).create(recursive: true);
      final sourceFile = File(p.join(directory.path, 'Info.plist'));
      await sourceFile.writeAsString('framework');
      String? alias;
      addTearDown(() async {
        if (alias != null &&
            FileSystemEntity.typeSync(alias, followLinks: false) !=
                FileSystemEntityType.notFound) {
          await Directory(alias).delete();
          expect(sourceFile.existsSync(), isTrue);
        }
        await scratch.delete(recursive: true);
      });
      final original = plan(extendedSource);
      final staged = await repairs.stageWindowsDirectoryCopyInputs(
        original,
        scratch.path,
      );
      final decoded = jsonDecode(staged) as Map<String, dynamic>;
      final commands = decoded['copyCommands'] as Map<String, dynamic>;
      final command = commands['framework-copy'] as Map<String, dynamic>;
      alias =
          ((command['inputs'] as List<dynamic>).single
                  as Map<String, dynamic>)['name']
              as String;
      expect(alias, isNot(extendedSource));
      expect(p.isWithin(scratch.path, alias), isTrue);
      expect(
        await Directory(alias).resolveSymbolicLinks(),
        await Directory(extendedSource).resolveSymbolicLinks().then(
          (resolved) =>
              resolved.startsWith(r'\\?\') ? resolved.substring(4) : resolved,
        ),
      );
      expect(File(p.join(alias, 'Info.plist')).readAsStringSync(), 'framework');
      expect(
        await repairs.stageWindowsDirectoryCopyInputs(staged, scratch.path),
        staged,
      );
    },
    skip: !Platform.isWindows,
    // PowerShell junction creation is slow on Windows ARM64 runners.
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('long-path staging leaves POSIX plans untouched', () async {
    expect(
      await posix.hostPolicy.repairBuildPlan(r'C:\scratch', r'C:\scratch'),
      isFalse,
    );
  });

  test('removing scratch does not remove a junction target', () async {
    final fixture = await Directory.systemTemp.createTemp('xcross-copy-safe-');
    final scratch = await Directory.systemTemp.createTemp('xcross-scratch-');
    addTearDown(() async {
      if (scratch.existsSync()) await scratch.delete(recursive: true);
      if (fixture.existsSync()) await fixture.delete(recursive: true);
    });
    var source = p.join(fixture.path, 'vendor');
    while (source.length < 265) {
      source = p.join(source, 'nested-framework-source');
    }
    await Directory(r'\\?\' + source).create(recursive: true);
    final sentinel = File(p.join(r'\\?\' + source, 'keep.txt'));
    await sentinel.writeAsString('keep');

    await repairs.stageWindowsDirectoryCopyInputs(
      plan(r'\\?\' + source),
      scratch.path,
    );
    await scratch.delete(recursive: true);
    expect(sentinel.readAsStringSync(), 'keep');
  }, skip: !Platform.isWindows);

  test('preserves ordinary paths, UNC paths, files and unrelated plans', () {
    for (final original in [
      plan(r'C:\Example.framework'),
      plan('/tmp/Example.framework'),
      plan(r'\\?\UNC\server\share\Example.framework'),
      plan(r'\\?\C:\example.txt', kind: 'file'),
      '{ "swiftCommands": {} }',
    ]) {
      expect(repairs.normalizeWindowsDirectoryCopyInputs(original), original);
    }
  });

  test('generated-file repair is Windows-only and idempotent', () async {
    final scratch = await Directory.systemTemp.createTemp('xcross-copy-plan-');
    addTearDown(() => scratch.delete(recursive: true));
    final target = await Directory(p.join(scratch.path, 'debug')).create();
    final description = File(p.join(target.path, 'description.json'));
    final original = plan(r'\\?\C:\vendor\Example.framework');
    await description.writeAsString(original);
    expect(
      await posix.hostPolicy.repairBuildPlan(scratch.path, target.path),
      isFalse,
    );
    expect(await description.readAsString(), original);
    expect(
      await repairs.repairWindowsGeneratedBuildFiles(scratch.path, target.path),
      isTrue,
    );
    expect(
      await repairs.repairWindowsGeneratedBuildFiles(scratch.path, target.path),
      isFalse,
    );
  });

  for (final (architecture, triple, other) in [
    ('arm64', 'aarch64-unknown-windows-msvc', 'x86_64-unknown-windows-msvc'),
    ('x64', 'x86_64-unknown-windows-msvc', 'aarch64-unknown-windows-msvc'),
  ]) {
    test('repairs the $architecture host plugin tools description', () async {
      final scratch = await Directory.systemTemp.createTemp(
        'xcross-plugin-tools-',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final target = await Directory(
        p.join(scratch.path, 'arm64-apple-ios', 'debug'),
      ).create(recursive: true);
      const broken = r'{"path":"\\\\?\\C:\\?\\C:\\tools\\plugin.exe"}';
      File description(String triple) => File(
        p.join(scratch.path, triple, 'debug', 'plugin-tools-description.json'),
      )..createSync(recursive: true);
      final host = description(triple)..writeAsStringSync(broken);
      final foreign = description(other)..writeAsStringSync(broken);
      final repairs = WindowsSwiftPlanRepair(
        testWindowsSwiftPmRuntime(architecture: architecture).runner,
      );

      expect(
        await repairs.repairWindowsGeneratedBuildFiles(
          scratch.path,
          target.path,
        ),
        isTrue,
      );
      expect(host.readAsStringSync(), r'{"path":"C:\\tools\\plugin.exe"}');
      expect(foreign.readAsStringSync(), broken);
    });
  }
}
