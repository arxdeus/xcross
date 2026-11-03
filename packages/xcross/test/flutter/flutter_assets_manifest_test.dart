import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/flutter_assets_compiler.dart';
import 'package:xcross/src/shared/flutter/project/pubspec_info_reader.dart';

import '../apple/support/native_test_file_system.dart';

void main() {
  /// `AssetManifest.bin` written by `flutter build bundle` (Flutter 3.47) for
  /// the project [writeProject] creates.
  final fixture = p.join(
    'test',
    'flutter',
    'fixtures',
    'asset_manifest_variants.bin',
  );

  late Directory tmp;
  late String app;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xcross_assets_manifest_');
    app = p.join(tmp.path, 'app');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String path, String contents) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  void writeProject({String appAssets = ''}) {
    final dep = p.join(tmp.path, 'dep');
    write(p.join(dep, 'assets', 'a.json'), 'd');
    write(p.join(dep, 'assets', '2.0x', 'a.json'), 'd2');
    write(p.join(dep, 'pubspec.yaml'), '''
name: dep
flutter:
  assets:
    - assets/
''');
    write(p.join(app, 'assets', 'img', 'x.png'), 'i');
    write(p.join(app, 'assets', 'img', '3.0x', 'x.png'), 'i3');
    write(p.join(app, 'assets', 'img', 'sub', 'no.txt'), 'nested');
    write(p.join(app, 'assets', 'web.txt'), 'w');
    write(p.join(app, 'pubspec.yaml'), '''
name: app
dependencies:
  dep:
    path: ../dep
flutter:
  assets:
    - assets/img/
    - path: assets/web.txt
      platforms: [web]
$appAssets''');
    write(
      p.join(app, '.dart_tool', 'package_config.json'),
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'dep',
            'rootUri': p.toUri('$dep${p.separator}').toString(),
            'packageUri': 'lib/',
          },
          {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
        ],
      }),
    );
    write(
      p.join(app, '.dart_tool', 'package_graph.json'),
      jsonEncode({
        'configVersion': 1,
        'roots': ['app'],
        'packages': [
          {
            'name': 'app',
            'dependencies': ['dep'],
            'devDependencies': <String>[],
          },
          {'name': 'dep', 'dependencies': <String>[]},
        ],
      }),
    );
  }

  Future<(Map<String, List<String>>, String)> bundle() async {
    // The host's own file system and path style, so the test also runs on
    // Windows (the iPhone test runtime is a Linux host).
    const fileSystem = NativeTestFileSystem();
    final compiler = FlutterAssetsCompiler(
      fileSystem: fileSystem,
      paths: p.context,
      projectRoot: app,
      flutterRoot: p.join(tmp.path, 'flutter'),
    );
    final out = p.join(tmp.path, 'out');
    Directory(out).createSync();
    final manifest = await compiler.copyPubspecAssets(
      out,
      PubspecInfoReader(fileSystem, p.context).loadSync(app),
    );
    compiler.writeManifests(out, manifest, const []);
    return (manifest, out);
  }

  test(
    'bundles dependency assets, variants and filters like flutter_tools',
    () async {
      writeProject();
      final (manifest, out) = await bundle();

      expect(manifest, {
        'assets/img/x.png': ['assets/img/x.png', 'assets/img/3.0x/x.png'],
        'packages/dep/assets/a.json': [
          'packages/dep/assets/a.json',
          'packages/dep/assets/2.0x/a.json',
        ],
      });
      for (final key in [
        'assets/img/x.png',
        'assets/img/3.0x/x.png',
        'packages/dep/assets/a.json',
        'packages/dep/assets/2.0x/a.json',
      ]) {
        expect(
          File(p.joinAll([out, ...p.url.split(key)])).existsSync(),
          isTrue,
        );
      }
      // Directory entries are non-recursive; web-only entries are skipped.
      expect(
        File(p.join(out, 'assets', 'img', 'sub', 'no.txt')).existsSync(),
        isFalse,
      );
      expect(File(p.join(out, 'assets', 'web.txt')).existsSync(), isFalse);
      expect(File(p.join(out, 'AssetManifest.json')).existsSync(), isFalse);

      expect(
        File(p.join(out, 'AssetManifest.bin')).readAsBytesSync(),
        File(fixture).readAsBytesSync(),
      );
      expect(File(p.join(out, 'FontManifest.json')).readAsStringSync(), '[]');
    },
  );

  test('parses the device pixel ratio of variant directories', () {
    expect(FlutterAssetsCompiler.devicePixelRatio('a/2.0x/b.png'), 2.0);
    expect(FlutterAssetsCompiler.devicePixelRatio('a/3x/b.png'), 3.0);
    expect(FlutterAssetsCompiler.devicePixelRatio('a/b.png'), isNull);
    expect(FlutterAssetsCompiler.devicePixelRatio('b.png'), isNull);
  });

  test('refuses asset transformers instead of skipping them', () async {
    writeProject(
      appAssets: '''
    - path: assets/web.txt
      transformers:
        - package: vector_graphics_compiler
''',
    );
    await expectLater(
      bundle(),
      throwsA(
        isA<FlutterBuildError>().having(
          (e) => e.message,
          'message',
          contains('transformers'),
        ),
      ),
    );
  });
}
