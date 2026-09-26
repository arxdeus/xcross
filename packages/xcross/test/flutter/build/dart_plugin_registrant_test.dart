import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/dart_plugin_registrant.dart';
import 'package:xcross/src/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/flutter/build/flutter_packer.dart';
import 'package:xcross/src/flutter/build/hot_reload_setup.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';

void main() {
  _frontendServerFlags();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_dart_registrant-');
  });

  tearDown(() => tmp.delete(recursive: true));

  /// Writes a plugin package whose pubspec declares the given iOS keys.
  IosPlugin writePlugin(
    String name, {
    String? dartPluginClass,
    String? pluginClass,
    String? dartFileName,
  }) {
    final packageRoot = p.join(tmp.path, name);
    Directory(packageRoot).createSync(recursive: true);

    final entries = [
      if (pluginClass != null) '        pluginClass: $pluginClass',
      if (dartPluginClass != null) '        dartPluginClass: $dartPluginClass',
      if (dartFileName != null) '        dartFileName: $dartFileName',
    ];
    final pluginSection = entries.isEmpty
        ? ''
        : '''
flutter:
  plugin:
    platforms:
      ios:
${entries.join('\n')}
''';
    File(
      p.join(packageRoot, 'pubspec.yaml'),
    ).writeAsStringSync('name: $name\n$pluginSection');

    return IosPlugin(name: name, packageRoot: packageRoot);
  }

  test(
    'reload restores custom registrant and matches build compiler inputs',
    () async {
      final previousDirectory = Directory.current;
      final flutterRoot = p.join(tmp.path, 'flutter');
      final snapshot = File(
        p.join(
          flutterRoot,
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          'snapshots',
          'frontend_server_aot.dart.snapshot',
        ),
      );
      await snapshot.create(recursive: true);
      await Directory(
        p.join(
          flutterRoot,
          'bin',
          'cache',
          'artifacts',
          'engine',
          'common',
          'flutter_patched_sdk',
        ),
      ).create(recursive: true);
      final projectRoot = await tmp.resolveSymbolicLinks();
      final packageConfig = File(
        p.join(projectRoot, '.dart_tool', 'package_config.json'),
      );
      await packageConfig.parent.create(recursive: true);
      await packageConfig.writeAsString(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'app',
              'rootUri': '../',
              'packageUri': 'lib/',
              'languageVersion': '3.0',
            },
          ],
        }),
      );
      final plugin = writePlugin('dart_plugin', dartPluginClass: 'DartPlugin');
      final metadata = File(
        p.join(projectRoot, '.flutter-plugins-dependencies'),
      );
      await metadata.writeAsString(
        jsonEncode({
          'plugins': {
            'ios': [
              {'name': plugin.name, 'path': plugin.packageRoot},
            ],
          },
        }),
      );
      await DartPluginRegistrant.generate(
        projectRoot: projectRoot,
        plugins: [plugin],
        entrypointUri: 'package:app/main.dart',
      );
      final registrant = File(DartPluginRegistrant.pathFor(projectRoot));
      final initialSource = await registrant.readAsString();
      await registrant.writeAsString('native assemble overwrote this');
      final seed = File(
        p.join(
          projectRoot,
          'build',
          'xcross-flutter-debug',
          '.kernel',
          'app.dill',
        ),
      );
      await seed.create(recursive: true);
      await seed.writeAsString('warm-start seed');
      FlutterPacker.configureFlutterRootOverride(flutterRoot);
      Directory.current = projectRoot;
      try {
        final config = (await HotReloadSetup.buildHotReloadConfig(
          target: 'lib/main.dart',
          dartDefines: const ['USER=value'],
          flavor: 'dev',
        ))!;
        final registrantUri = Uri.file(registrant.path).toString();
        expect(config.dartDefines, [
          'USER=value',
          'FLUTTER_APP_FLAVOR=dev',
          'flutter.dart_plugin_registrant=$registrantUri',
        ]);
        expect(config.additionalSources.map((uri) => uri.toString()), [
          registrantUri,
          'package:flutter/src/dart_plugin_registrant.dart',
        ]);
        expect(await registrant.readAsString(), initialSource);
        expect(await seed.readAsString(), 'warm-start seed');
        expect(config.entrypoint, p.join(projectRoot, 'lib', 'main.dart'));
        await metadata.delete();
        final withoutPlugins = (await HotReloadSetup.buildHotReloadConfig(
          target: 'lib/main.dart',
          dartDefines: const ['FLUTTER_APP_FLAVOR=custom'],
          flavor: 'dev',
        ))!;
        expect(withoutPlugins.dartDefines, ['FLUTTER_APP_FLAVOR=custom']);
        expect(withoutPlugins.additionalSources, isEmpty);
        expect(registrant.existsSync(), isFalse);
      } finally {
        Directory.current = previousDirectory;
        FlutterPacker.resetFlutterRootOverride();
      }
    },
  );

  group('resolveRegistrations', () {
    test('selects only plugins declaring a dartPluginClass', () {
      final registrations = DartPluginRegistrant.resolveRegistrations([
        writePlugin(
          'dart_and_native',
          pluginClass: 'NativePlugin',
          dartPluginClass: 'DartPlugin',
        ),
        writePlugin('native_only', pluginClass: 'NativeOnlyPlugin'),
        writePlugin('no_plugin_section'),
      ]);

      expect(registrations, hasLength(1));
      expect(registrations.single.pluginName, 'dart_and_native');
      expect(registrations.single.dartClass, 'DartPlugin');
    });

    test('defaults dartFileName to <pluginName>.dart', () {
      final registrations = DartPluginRegistrant.resolveRegistrations([
        writePlugin('url_launcher_ios', dartPluginClass: 'UrlLauncherIOS'),
      ]);

      expect(registrations.single.dartFileName, 'url_launcher_ios.dart');
      expect(
        registrations.single.importUri,
        'package:url_launcher_ios/url_launcher_ios.dart',
      );
    });

    test('honours an explicit dartFileName', () {
      final registrations = DartPluginRegistrant.resolveRegistrations([
        writePlugin(
          'some_plugin',
          dartPluginClass: 'SomePlugin',
          dartFileName: 'src/some_plugin.dart',
        ),
      ]);

      expect(
        registrations.single.importUri,
        'package:some_plugin/src/some_plugin.dart',
      );
    });

    test('sorts by plugin name so output is build-stable', () {
      final registrations = DartPluginRegistrant.resolveRegistrations([
        writePlugin('zebra', dartPluginClass: 'Zebra'),
        writePlugin('alpha', dartPluginClass: 'Alpha'),
        writePlugin('middle', dartPluginClass: 'Middle'),
      ]);

      expect(registrations.map((r) => r.pluginName), [
        'alpha',
        'middle',
        'zebra',
      ]);
    });

    test('tolerates a missing or malformed pubspec', () {
      final missing = IosPlugin(
        name: 'gone',
        packageRoot: p.join(tmp.path, 'gone'),
      );
      final badRoot = p.join(tmp.path, 'bad');
      Directory(badRoot).createSync(recursive: true);
      File(p.join(badRoot, 'pubspec.yaml')).writeAsStringSync('\t: : not yaml');
      final malformed = IosPlugin(name: 'bad', packageRoot: badRoot);

      expect(
        DartPluginRegistrant.resolveRegistrations([missing, malformed]),
        isEmpty,
      );
    });
  });

  group('render', () {
    test('emits the vm:entry-point shape the engine looks for', () {
      final source = DartPluginRegistrant.render(const [
        DartPluginRegistration(
          pluginName: 'plugin_a',
          dartClass: 'PluginA',
          dartFileName: 'plugin_a.dart',
        ),
      ]);

      // The VM finds registration by this exact class/method name, and both
      // pragmas keep it from being tree-shaken.
      expect(source, contains("@pragma('vm:entry-point')"));
      expect(source, contains('class _PluginRegistrant {'));
      expect(source, contains('static void register() {'));
      expect(source, contains('if (Platform.isIOS) {'));
      expect(source, contains("import 'package:plugin_a/plugin_a.dart'"));
      expect(source, contains('plugin_a.PluginA.registerWith();'));
      // A throwing plugin must not abort the remaining registrations.
      expect(source, contains('} catch (err) {'));
    });

    test('registers every plugin in order', () {
      final source = DartPluginRegistrant.render(const [
        DartPluginRegistration(
          pluginName: 'a_plugin',
          dartClass: 'APlugin',
          dartFileName: 'a_plugin.dart',
        ),
        DartPluginRegistration(
          pluginName: 'b_plugin',
          dartClass: 'BPlugin',
          dartFileName: 'b_plugin.dart',
        ),
      ]);

      expect(
        source.indexOf('a_plugin.APlugin.registerWith();'),
        lessThan(source.indexOf('b_plugin.BPlugin.registerWith();')),
      );
    });
  });

  group('generate', () {
    test('writes the registrant where flutter_tools puts it', () async {
      final path = await DartPluginRegistrant.generate(
        projectRoot: tmp.path,
        plugins: [writePlugin('plugin_a', dartPluginClass: 'PluginA')],
        entrypointUri: 'package:app/main.dart',
      );

      expect(path, DartPluginRegistrant.pathFor(tmp.path));
      expect(
        path,
        p.join(
          tmp.path,
          '.dart_tool',
          'flutter_build',
          'dart_plugin_registrant.dart',
        ),
      );
      final source = File(path!).readAsStringSync();
      expect(source, contains('plugin_a.PluginA.registerWith();'));
      expect(source, contains('package:app/main.dart'));
    });

    test('returns null and writes nothing with no Dart plugins', () async {
      final path = await DartPluginRegistrant.generate(
        projectRoot: tmp.path,
        plugins: [writePlugin('native_only', pluginClass: 'NativeOnly')],
      );

      expect(path, isNull);
      expect(
        File(DartPluginRegistrant.pathFor(tmp.path)).existsSync(),
        isFalse,
      );
    });

    test('deletes a stale registrant when the last plugin goes away', () async {
      final first = await DartPluginRegistrant.generate(
        projectRoot: tmp.path,
        plugins: [writePlugin('plugin_a', dartPluginClass: 'PluginA')],
      );
      expect(File(first!).existsSync(), isTrue);

      // Removing the plugin must remove the file: a stale registrant would
      // keep importing a package that is no longer a dependency, which fails
      // the kernel compile outright.
      final second = await DartPluginRegistrant.generate(
        projectRoot: tmp.path,
        plugins: const [],
      );

      expect(second, isNull);
      expect(File(first).existsSync(), isFalse);
    });

    test('regenerating is stable for an unchanged plugin set', () async {
      final plugins = [writePlugin('plugin_a', dartPluginClass: 'PluginA')];

      final first = await DartPluginRegistrant.generate(
        projectRoot: tmp.path,
        plugins: plugins,
      );
      final firstSource = File(first!).readAsStringSync();
      final second = await DartPluginRegistrant.generate(
        projectRoot: tmp.path,
        plugins: plugins,
      );

      expect(second, first);
      expect(File(second!).readAsStringSync(), firstSource);
    });
  });
}

/// Guards the flags that carry the registrant to the compiler and the VM.
///
/// This is asserted on source text because `_frontendServerArgs` is private
/// and needs a live engine cache to call; the exact flag trio is what makes
/// registration actually run, so it is worth pinning regardless.
void _frontendServerFlags() {
  group('frontend_server registrant flags', () {
    // Git may check this source out with CRLF on Windows, so normalize before
    // matching against LF-embedded expectations. Same hazard the sibling
    // preview-macro-stub test documents.
    final source = _bundlerSource().readAsStringSync().replaceAll('\r\n', '\n');

    test('passes the registrant, the flutter shim, and the define', () {
      const registrant = 'file:///project/.dart_tool/flutter_build/r.dart';
      expect(
        FlutterDebugBundler.additionalSources(
          registrant,
        ).map((uri) => uri.toString()),
        [registrant, 'package:flutter/src/dart_plugin_registrant.dart'],
      );
      expect(
        FlutterDebugBundler.effectiveDartDefines(
          dartDefines: const ['USER=value'],
          registrantUri: registrant,
        ),
        ['USER=value', 'flutter.dart_plugin_registrant=$registrant'],
      );
    });

    test('mirrors flutter_tools debug incremental compile flags', () {
      // --incremental + --initialize-from-dill let frontend_server warm-start
      // from the previous app.dill instead of recompiling the whole program;
      // --no-link-platform matches flutter_tools' iOS KernelSnapshot target.
      expect(source, contains("'--incremental'"));
      expect(source, contains("'--initialize-from-dill', outputDill"));
      expect(source, contains("'--no-link-platform'"));
      // The three flags above must not have displaced the registrant trio.
      expect(source, contains("additionalSources(dartPluginRegistrantUri)"));
    });

    test('flavor default preserves explicit defines and input list', () {
      final defines = ['USER=value'];
      expect(
        FlutterDebugBundler.effectiveDartDefines(
          dartDefines: defines,
          flavor: 'dev',
        ),
        ['USER=value', 'FLUTTER_APP_FLAVOR=dev'],
      );
      expect(defines, ['USER=value']);
      expect(
        FlutterDebugBundler.effectiveDartDefines(
          dartDefines: const ['FLUTTER_APP_FLAVOR=custom'],
          flavor: 'dev',
        ),
        ['FLUTTER_APP_FLAVOR=custom'],
      );
      expect(
        FlutterDebugBundler.effectiveDartDefines(dartDefines: const []),
        isEmpty,
      );
      expect(FlutterDebugBundler.additionalSources(null), isEmpty);
    });

    test('builds a file:// URI rather than a bare path', () {
      // A bare path silently disables registration: the engine matches this
      // define against library importUris, and a path matches none.
      expect(
        FlutterDebugBundler.dartPluginRegistrantUri(
          p.join(p.separator, 'proj', '.dart_tool', 'flutter_build', 'r.dart'),
          null,
        ),
        startsWith('file:///'),
      );
    });
  });
}

/// Resolves the bundler source regardless of where `dart test` was invoked.
///
/// CI runs `dart test packages/xcross` from the repo root, so
/// `Directory.current` is the repo root and the package-relative form does not
/// resolve; running `dart test` from inside the package is the opposite. Try
/// both rather than pinning the file load to one working directory.
File _bundlerSource() {
  const relative = 'lib/src/flutter/build/flutter_debug_bundler.dart';
  final fromPackageRoot = File(relative);
  if (fromPackageRoot.existsSync()) return fromPackageRoot;
  return File(p.join('packages', 'xcross', relative));
}
