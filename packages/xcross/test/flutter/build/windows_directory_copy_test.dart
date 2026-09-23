import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';

void main() {
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
      final result =
          GeneratedPluginsPackage.normalizeWindowsDirectoryCopyInputs(original);
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
      expect(
        GeneratedPluginsPackage.normalizeWindowsDirectoryCopyInputs(result),
        result,
      );
    },
  );

  test('retains extended paths when the source exceeds MAX_PATH', () {
    final source = '${r'\\?\e:\'}${r'nested\' * 50}Example.framework';
    final original = plan(source);
    expect(
      GeneratedPluginsPackage.normalizeWindowsDirectoryCopyInputs(original),
      original,
    );
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
      final staged =
          await GeneratedPluginsPackage.stageWindowsDirectoryCopyInputs(
            original,
            scratch.path,
            windows: true,
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
        p.normalize(source),
      );
      expect(File(p.join(alias, 'Info.plist')).readAsStringSync(), 'framework');
      expect(
        await GeneratedPluginsPackage.stageWindowsDirectoryCopyInputs(
          staged,
          scratch.path,
          windows: true,
        ),
        staged,
      );
    },
    skip: !Platform.isWindows,
  );

  test('long-path staging leaves non-Windows plans untouched', () async {
    final original = plan(r'\\?\C:\very\long\Framework.framework');
    expect(
      await GeneratedPluginsPackage.stageWindowsDirectoryCopyInputs(
        original,
        r'C:\scratch',
        windows: false,
      ),
      original,
    );
  });

  test(
    'removing scratch does not remove a junction target',
    () async {
      final fixture = await Directory.systemTemp.createTemp(
        'xcross-copy-safe-',
      );
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

      await GeneratedPluginsPackage.stageWindowsDirectoryCopyInputs(
        plan(r'\\?\' + source),
        scratch.path,
        windows: true,
      );
      await scratch.delete(recursive: true);
      expect(sentinel.readAsStringSync(), 'keep');
    },
    skip: !Platform.isWindows,
  );

  test('preserves ordinary paths, UNC paths, files and unrelated plans', () {
    for (final original in [
      plan(r'C:\Example.framework'),
      plan('/tmp/Example.framework'),
      plan(r'\\?\UNC\server\share\Example.framework'),
      plan(r'\\?\C:\example.txt', kind: 'file'),
      '{ "swiftCommands": {} }',
    ]) {
      expect(
        GeneratedPluginsPackage.normalizeWindowsDirectoryCopyInputs(original),
        original,
      );
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
      await GeneratedPluginsPackage.repairWindowsGeneratedBuildFiles(
        scratch.path,
        target.path,
        windows: false,
      ),
      isFalse,
    );
    expect(await description.readAsString(), original);
    expect(
      await GeneratedPluginsPackage.repairWindowsGeneratedBuildFiles(
        scratch.path,
        target.path,
        windows: true,
      ),
      isTrue,
    );
    expect(
      await GeneratedPluginsPackage.repairWindowsGeneratedBuildFiles(
        scratch.path,
        target.path,
        windows: true,
      ),
      isFalse,
    );
  });
}
