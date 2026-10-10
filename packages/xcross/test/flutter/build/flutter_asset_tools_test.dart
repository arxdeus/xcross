@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/icon_tree_shaker.dart';
import 'package:xcross/src/shared/flutter/build/impeller_shader_compiler.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/flutter_assets_compiler.dart';

import '../flutter_test_log.dart';
import '../flutter_test_runtime.dart';

void main() {
  late Directory tmp;
  late LinuxHost host;
  late ProcessRunner<LinuxHost> runner;
  late RecordingFlutterLogOutput output;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xcross_asset_tools_');
    host = LinuxHost(currentDirectory: tmp.path, temporaryDirectory: tmp.path);
    output = RecordingFlutterLogOutput();
    runner = ProcessRunner(
      host,
      log: Log(output: output),
      stdinStream: const Stream<List<int>>.empty(),
      stdoutSink: IOSink(StreamController<List<int>>().sink),
      stderrSink: IOSink(StreamController<List<int>>().sink),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String script(String name, String body) {
    final file = File(p.join(tmp.path, 'tools', name))
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n$body');
    host.fileSystem.makeExecutable(file.path);
    return file.path;
  }

  /// Stand-in impellerc: records its arguments and writes the `--sl` and
  /// `--spirv` outputs like the real compiler.
  String impellerc() => script('impellerc', r'''
for argument in "$@"; do
  case "$argument" in
    --sl=*) sl="${argument#--sl=}" ;;
    --spirv=*) spirv="${argument#--spirv=}" ;;
    --input=*) input="${argument#--input=}" ;;
  esac
done
printf '%s\n' "$*" >> "$(dirname "$0")/impellerc.log"
printf 'IPLR:%s' "$(cat "$input")" > "$sl"
printf 'spirv' > "$spirv"
''');

  group('ImpellerShaderCompiler', () {
    test('passes the iOS runtime stage arguments flutter_tools uses', () {
      final compiler = ImpellerShaderCompiler(
        runner: runner,
        impellerc: '/engine/impellerc',
        shaderLib: '/engine/shader_lib',
      );
      expect(
        compiler.arguments(
          source: '/app/shaders/glow.frag',
          output: '/out/flutter_assets/shaders/glow.frag',
        ),
        [
          '--runtime-stage-metal',
          '--iplr',
          '--sl=/out/flutter_assets/shaders/glow.frag',
          '--spirv=/out/flutter_assets/shaders/glow.frag.spirv',
          '--input=/app/shaders/glow.frag',
          '--input-type=frag',
          '--include=/app/shaders',
          '--include=/engine/shader_lib',
        ],
      );
    });

    test('writes the runtime stage and drops the SPIR-V side output', () async {
      final source = File(p.join(tmp.path, 'glow.frag'))
        ..writeAsStringSync('void main() {}');
      final output = p.join(tmp.path, 'assets', 'shaders', 'glow.frag');
      await ImpellerShaderCompiler(
        runner: runner,
        impellerc: impellerc(),
        shaderLib: '/engine/shader_lib',
      ).compile(source: source.path, output: output);
      expect(File(output).readAsStringSync(), 'IPLR:void main() {}');
      expect(File('$output.spirv').existsSync(), isFalse);
    });

    test('fails the build when impellerc fails', () async {
      final source = File(p.join(tmp.path, 'broken.frag'))
        ..writeAsStringSync('nope');
      await expectLater(
        ImpellerShaderCompiler(
          runner: runner,
          impellerc: script('impellerc', 'echo "syntax error" >&2\nexit 1\n'),
          shaderLib: '/engine/shader_lib',
        ).compile(
          source: source.path,
          output: p.join(tmp.path, 'out', 'broken.frag'),
        ),
        throwsA(anything),
      );
    });
  });

  group('FlutterAssetsCompiler shaders', () {
    late String flutterRoot;
    late String assets;

    setUp(() {
      flutterRoot = p.join(tmp.path, 'flutter');
      assets = p.join(tmp.path, 'flutter_assets');
      Directory(p.join(tmp.path, '.dart_tool')).createSync();
      File(p.join(tmp.path, '.dart_tool', 'package_config.json'))
          .writeAsStringSync('{"configVersion":2,"packages":[]}');
    });

    void frameworkShader(String layer, String name) {
      File(
          p.join(
            flutterRoot,
            'packages',
            'flutter',
            'lib',
            'src',
            layer,
            'shaders',
            name,
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('$layer/$name');
    }

    FlutterAssetsCompiler compiler({String? flavor}) => FlutterAssetsCompiler(
      fileSystem: host.fileSystem,
      paths: host.paths.context,
      projectRoot: tmp.path,
      flutterRoot: flutterRoot,
      flavor: flavor,
    );

    test('bundles the framework shaders, preferring the widgets layer', () {
      frameworkShader('material', 'ink_sparkle.frag');
      frameworkShader('material', 'stretch_effect.frag');
      frameworkShader('widgets', 'stretch_effect.frag');
      expect(compiler().frameworkShaders(), {
        'shaders/ink_sparkle.frag': p.join(
          flutterRoot,
          'packages',
          'flutter',
          'lib',
          'src',
          'material',
          'shaders',
          'ink_sparkle.frag',
        ),
        'shaders/stretch_effect.frag': p.join(
          flutterRoot,
          'packages',
          'flutter',
          'lib',
          'src',
          'widgets',
          'shaders',
          'stretch_effect.frag',
        ),
      });
    });

    test('falls back to the material stretch shader on older SDKs', () {
      frameworkShader('material', 'stretch_effect.frag');
      expect(compiler().frameworkShaders(), {
        'shaders/stretch_effect.frag': p.join(
          flutterRoot,
          'packages',
          'flutter',
          'lib',
          'src',
          'material',
          'shaders',
          'stretch_effect.frag',
        ),
      });
    });

    test(
      'compiles app, package and framework shaders and lists declared ones',
      () async {
        frameworkShader('material', 'ink_sparkle.frag');
        frameworkShader('widgets', 'stretch_effect.frag');
        final package = Directory(p.join(tmp.path, 'effects'))..createSync();
        File(p.join(package.path, 'shaders', 'blur.frag'))
          ..createSync(recursive: true)
          ..writeAsStringSync('blur');
        File(p.join(package.path, 'pubspec.yaml')).writeAsStringSync('''
name: effects
flutter:
  shaders:
    - shaders/blur.frag
''');
        File(p.join(tmp.path, '.dart_tool', 'package_config.json'))
            .writeAsStringSync(
              jsonEncode({
                'configVersion': 2,
                'packages': [
                  {
                    'name': 'effects',
                    'rootUri': package.uri.toString(),
                    'packageUri': 'lib/',
                  },
                ],
              }),
            );
        File(p.join(tmp.path, 'shaders', 'glow.frag'))
          ..createSync(recursive: true)
          ..writeAsStringSync('glow');
        File(p.join(tmp.path, 'shaders', 'dark.frag'))
            .writeAsStringSync('dark');
        File(p.join(tmp.path, 'shaders', 'web.frag')).writeAsStringSync('web');
        File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
dependencies:
  effects: any
flutter:
  shaders:
    - shaders/glow.frag
    - path: shaders/dark.frag
      flavors: [dark]
    - path: shaders/web.frag
      platforms: [web]
''');
        final manifest = <String, List<String>>{};
        await compiler(flavor: 'dark').compileShaders(
          assets,
          testIPhoneRuntime().pubspecs.loadSync(tmp.path),
          ImpellerShaderCompiler(
            runner: runner,
            impellerc: impellerc(),
            shaderLib: '/engine/shader_lib',
          ),
          manifest,
        );
        String read(String key) =>
            File(p.joinAll([assets, ...p.url.split(key)])).readAsStringSync();
        expect(read('shaders/glow.frag'), 'IPLR:glow');
        expect(read('shaders/dark.frag'), 'IPLR:dark');
        expect(read('packages/effects/shaders/blur.frag'), 'IPLR:blur');
        expect(
          read('shaders/ink_sparkle.frag'),
          'IPLR:material/ink_sparkle.frag',
        );
        expect(
          read('shaders/stretch_effect.frag'),
          'IPLR:widgets/stretch_effect.frag',
        );
        expect(
          File(p.join(assets, 'shaders', 'web.frag')).existsSync(),
          isFalse,
        );
        expect(manifest, {
          'shaders/glow.frag': ['shaders/glow.frag'],
          'shaders/dark.frag': ['shaders/dark.frag'],
          'packages/effects/shaders/blur.frag': [
            'packages/effects/shaders/blur.frag',
          ],
        });
      },
    );

    test(
      'resolves packages/<pkg>/ shader paths inside the package lib (#110)',
      () async {
        // material_ui declares `packages/material_ui/shaders/ink_sparkle.frag`,
        // which flutter_tools resolves to `<material_ui>/lib/shaders/...`.
        final package = Directory(p.join(tmp.path, 'material_ui'))
          ..createSync();
        File(p.join(package.path, 'lib', 'shaders', 'ink_sparkle.frag'))
          ..createSync(recursive: true)
          ..writeAsStringSync('sparkle');
        File(p.join(package.path, 'pubspec.yaml')).writeAsStringSync('''
name: material_ui
flutter:
  shaders:
    - packages/material_ui/shaders/ink_sparkle.frag
''');
        File(p.join(tmp.path, '.dart_tool', 'package_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({
              'configVersion': 2,
              'packages': [
                {
                  'name': 'material_ui',
                  'rootUri': package.uri.toString(),
                  'packageUri': 'lib/',
                },
              ],
            }),
          );
        File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
dependencies:
  material_ui: any
''');
        final manifest = <String, List<String>>{};
        await compiler().compileShaders(
          assets,
          testIPhoneRuntime().pubspecs.loadSync(tmp.path),
          ImpellerShaderCompiler(
            runner: runner,
            impellerc: impellerc(),
            shaderLib: '/engine/shader_lib',
          ),
          manifest,
        );
        const key = 'packages/material_ui/shaders/ink_sparkle.frag';
        expect(
          File(p.joinAll([assets, ...p.url.split(key)])).readAsStringSync(),
          'IPLR:sparkle',
        );
        expect(manifest, {
          key: [key],
        });
      },
    );

    test('skips flavored shaders when building without that flavor', () async {
      File(p.join(tmp.path, 'shaders', 'dark.frag'))
        ..createSync(recursive: true)
        ..writeAsStringSync('dark');
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
flutter:
  shaders:
    - path: shaders/dark.frag
      flavors: [dark]
''');
      final manifest = <String, List<String>>{};
      await compiler().compileShaders(
        assets,
        testIPhoneRuntime().pubspecs.loadSync(tmp.path),
        ImpellerShaderCompiler(
          runner: runner,
          impellerc: impellerc(),
          shaderLib: '/engine/shader_lib',
        ),
        manifest,
      );
      expect(manifest, isEmpty);
      expect(Directory(assets).existsSync(), isFalse);
    });

    for (final (assetsEntry, reason) in [
      ('shaders/glow.frag', 'is also defined as an asset'),
      ('shaders/', 'is included in the asset directory'),
    ]) {
      test('rejects a shader declared as an asset ($assetsEntry)', () async {
        File(p.join(tmp.path, 'shaders', 'glow.frag'))
          ..createSync(recursive: true)
          ..writeAsStringSync('glow');
        File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
flutter:
  assets:
    - $assetsEntry
  shaders:
    - shaders/glow.frag
''');
        await expectLater(
          compiler().compileShaders(
            assets,
            testIPhoneRuntime().pubspecs.loadSync(tmp.path),
            ImpellerShaderCompiler(
              runner: runner,
              impellerc: impellerc(),
              shaderLib: '/engine/shader_lib',
            ),
            {},
          ),
          throwsA(
            isA<FlutterBuildError>().having(
              (e) => e.toString(),
              'message',
              contains(reason),
            ),
          ),
        );
      });
    }

    test('reports a missing declared shader', () async {
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
flutter:
  shaders:
    - shaders/missing.frag
''');
      await expectLater(
        compiler().compileShaders(
          assets,
          testIPhoneRuntime().pubspecs.loadSync(tmp.path),
          ImpellerShaderCompiler(
            runner: runner,
            impellerc: impellerc(),
            shaderLib: '/engine/shader_lib',
          ),
          {},
        ),
        throwsA(isA<FlutterBuildError>()),
      );
    });

    test('refuses shader transformers instead of skipping them', () async {
      File(p.join(tmp.path, 'shaders', 'glow.frag'))
        ..createSync(recursive: true)
        ..writeAsStringSync('glow');
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
flutter:
  shaders:
    - path: shaders/glow.frag
      transformers:
        - package: shader_minifier
''');
      await expectLater(
        compiler().compileShaders(
          assets,
          testIPhoneRuntime().pubspecs.loadSync(tmp.path),
          ImpellerShaderCompiler(
            runner: runner,
            impellerc: impellerc(),
            shaderLib: '/engine/shader_lib',
          ),
          {},
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (e) => e.toString(),
            'message',
            contains('transformers'),
          ),
        ),
      );
    });
  });

  group('IconTreeShaker', () {
    String constFinderOutput(Object json) =>
        script('dart', "cat <<'JSON'\n${jsonEncode(json)}\nJSON\n");

    /// Stand-in font-subset: records argv and the code points from stdin, and
    /// writes a small subset like the real tool.
    String fontSubset() => script('font-subset', r'''
read -r codepoints
printf '%s|%s\n' "$*" "$codepoints" >> "$(dirname "$0")/font-subset.log"
printf 'subset' > "$1"
''');

    IconTreeShaker<LinuxHost> shaker({required String dart}) => IconTreeShaker(
      runner: runner,
      dart: dart,
      constFinder: '/engine/const_finder.dart.snapshot',
      fontSubset: fontSubset(),
    );

    test('maps constant IconData to font family keys', () async {
      final constants = await shaker(
        dart: constFinderOutput({
          'constantInstances': [
            {'codePoint': 58019, 'fontFamily': 'MaterialIcons'},
            {'codePoint': 57490.0, 'fontFamily': 'MaterialIcons'},
            {
              'codePoint': 61440,
              'fontFamily': 'CupertinoIcons',
              'fontPackage': 'cupertino_icons',
            },
            {'codePoint': 1, 'fontFamily': null},
          ],
          'nonConstantLocations': <Object>[],
        }),
      ).findConstants('/app.dill');
      expect(constants, {
        'MaterialIcons': [58019, 57490],
        'packages/cupertino_icons/CupertinoIcons': [61440],
      });
    });

    test('fails on non-constant IconData like flutter build does', () async {
      await expectLater(
        shaker(
          dart: constFinderOutput({
            'constantInstances': <Object>[],
            'nonConstantLocations': [
              {'file': 'lib/main.dart', 'line': 3, 'column': 9},
            ],
          }),
        ).findConstants('/app.dill'),
        throwsA(
          isA<FlutterBuildError>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('lib/main.dart:3:9'),
              contains('--no-tree-shake-icons'),
            ),
          ),
        ),
      );
    });

    test('reports a failing const_finder', () async {
      await expectLater(
        shaker(dart: script('dart', 'echo boom >&2\nexit 3\n'))
            .findConstants('/app.dill'),
        throwsA(
          isA<FlutterBuildError>().having(
            (e) => e.toString(),
            'message',
            contains('boom'),
          ),
        ),
      );
    });

    test('selects only single-file families the app references', () {
      expect(
        IconTreeShaker.iconFonts(
          [
            {
              'family': 'MaterialIcons',
              'fonts': [
                {'asset': 'fonts/MaterialIcons-Regular.otf'},
              ],
            },
            {
              'family': 'Body',
              'fonts': [
                {'asset': 'fonts/Body-Regular.ttf'},
                {'asset': 'fonts/Body-Bold.ttf', 'weight': 700},
              ],
            },
          ],
          {'MaterialIcons'},
        ),
        {'MaterialIcons': 'fonts/MaterialIcons-Regular.otf'},
      );
      expect(
        () => IconTreeShaker.iconFonts(
          [
            {
              'family': 'Icons',
              'fonts': [
                {'asset': 'a.ttf'},
                {'asset': 'b.ttf'},
              ],
            },
          ],
          {'Icons'},
        ),
        throwsA(isA<FlutterBuildError>()),
      );
    });

    test('accepts TrueType and OpenType files only', () {
      final header = List<int>.filled(12, 0);
      final woff2 = [...ascii.encode('wOF2'), ...List<int>.filled(8, 0)];
      expect(IconTreeShaker.isTrueTypeFont('Icons.ttf', header), isTrue);
      expect(IconTreeShaker.isTrueTypeFont('Icons.OTF', header), isTrue);
      expect(IconTreeShaker.isTrueTypeFont('Icons.woff', header), isFalse);
      expect(IconTreeShaker.isTrueTypeFont('Icons.ttf', woff2), isFalse);
      expect(IconTreeShaker.isTrueTypeFont('Icons.ttf', [0, 1]), isFalse);
    });

    test(
      'subsets referenced fonts in place through stdin code points',
      () async {
        final assets = Directory(p.join(tmp.path, 'assets'))..createSync();
        final material =
            File(p.join(assets.path, 'fonts', 'MaterialIcons-Regular.otf'))
              ..createSync(recursive: true)
              ..writeAsBytesSync(List<int>.filled(4096, 7));
        final unused = File(p.join(assets.path, 'fonts', 'Other.ttf'))
          ..writeAsBytesSync(List<int>.filled(64, 1));
        await shaker(
          dart: constFinderOutput({
            'constantInstances': [
              {'codePoint': 58019, 'fontFamily': 'MaterialIcons'},
              {'codePoint': 57490, 'fontFamily': 'MaterialIcons'},
            ],
            'nonConstantLocations': <Object>[],
          }),
        ).shake(
          assetsDir: assets.path,
          appDill: '/app.dill',
          fontManifest: [
            {
              'family': 'MaterialIcons',
              'fonts': [
                {'asset': 'fonts/MaterialIcons-Regular.otf'},
              ],
            },
            {
              'family': 'Other',
              'fonts': [
                {'asset': 'fonts/Other.ttf'},
              ],
            },
          ],
        );
        expect(material.readAsStringSync(), 'subset');
        expect(unused.lengthSync(), 64);
        expect(
          File(p.join(tmp.path, 'tools', 'font-subset.log')).readAsLinesSync(),
          ['${material.path}.subset ${material.path}|58019 57490'],
        );
        expect(
          output.messages.join('\n'),
          contains('reducing it from 4096 to 6 bytes'),
        );
      },
    );

    test('reports a failing font-subset', () async {
      final font = File(p.join(tmp.path, 'Icons.ttf'))
        ..writeAsBytesSync(List<int>.filled(32, 1));
      final failing = IconTreeShaker(
        runner: runner,
        dart: '/unused',
        constFinder: '/unused',
        fontSubset: script(
          'font-subset',
          'cat >/dev/null\necho bad >&2\nexit 2\n',
        ),
      );
      await expectLater(
        failing.subset(font.path, [1]),
        throwsA(
          isA<FlutterBuildError>().having(
            (e) => e.toString(),
            'message',
            contains('exit code 2'),
          ),
        ),
      );
      expect(font.lengthSync(), 32);
    });
  });
}
