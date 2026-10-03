import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/dart_plugin_registrant.dart';
import 'package:xcross/src/flutter/build/internal/kernel_compiler.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/shared/flutter/flutter_kernel_compiler.dart';

import '../flutter_test_runtime.dart';

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

    return IosPlugin(
      fileSystem: LinuxHost().fileSystem,
      name: name,
      packageRoot: packageRoot,
    );
  }

  group('resolveRegistrations', () {
    test('selects only plugins declaring a dartPluginClass', () {
      final registrations = DartPluginRegistrant(LinuxHost().fileSystem)
          .resolveRegistrations([
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
      final registrations = DartPluginRegistrant(LinuxHost().fileSystem)
          .resolveRegistrations([
            writePlugin('url_launcher_ios', dartPluginClass: 'UrlLauncherIOS'),
          ]);

      expect(registrations.single.dartFileName, 'url_launcher_ios.dart');
      expect(
        registrations.single.importUri,
        'package:url_launcher_ios/url_launcher_ios.dart',
      );
    });

    test('honours an explicit dartFileName', () {
      final registrations = DartPluginRegistrant(LinuxHost().fileSystem)
          .resolveRegistrations([
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
      final registrations = DartPluginRegistrant(LinuxHost().fileSystem)
          .resolveRegistrations([
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
        fileSystem: LinuxHost().fileSystem,
        name: 'gone',
        packageRoot: p.join(tmp.path, 'gone'),
      );
      final badRoot = p.join(tmp.path, 'bad');
      Directory(badRoot).createSync(recursive: true);
      File(p.join(badRoot, 'pubspec.yaml')).writeAsStringSync('\t: : not yaml');
      final malformed = IosPlugin(
        fileSystem: LinuxHost().fileSystem,
        name: 'bad',
        packageRoot: badRoot,
      );

      expect(
        DartPluginRegistrant(
          LinuxHost().fileSystem,
        ).resolveRegistrations([missing, malformed]),
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
      expect(source, contains("import 'dart:io';"));
      expect(source, contains('Platform.isIOS'));
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
      final path = await DartPluginRegistrant(LinuxHost().fileSystem).generate(
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
      final path = await DartPluginRegistrant(LinuxHost().fileSystem).generate(
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
      final first = await DartPluginRegistrant(LinuxHost().fileSystem).generate(
        projectRoot: tmp.path,
        plugins: [writePlugin('plugin_a', dartPluginClass: 'PluginA')],
      );
      expect(File(first!).existsSync(), isTrue);

      // Removing the plugin must remove the file: a stale registrant would
      // keep importing a package that is no longer a dependency, which fails
      // the kernel compile outright.
      final second = await DartPluginRegistrant(
        LinuxHost().fileSystem,
      ).generate(projectRoot: tmp.path, plugins: const []);

      expect(second, isNull);
      expect(File(first).existsSync(), isFalse);
    });

    test('regenerating is stable for an unchanged plugin set', () async {
      final plugins = [writePlugin('plugin_a', dartPluginClass: 'PluginA')];

      final first = await DartPluginRegistrant(
        LinuxHost().fileSystem,
      ).generate(projectRoot: tmp.path, plugins: plugins);
      final firstSource = File(first!).readAsStringSync();
      final second = await DartPluginRegistrant(
        LinuxHost().fileSystem,
      ).generate(projectRoot: tmp.path, plugins: plugins);

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
    test('passes the registrant, the flutter shim, and the define', () {
      final flutter = Directory.systemTemp.createTempSync(
        'xcross_frontend_args_',
      );
      addTearDown(() => flutter.deleteSync(recursive: true));
      Directory(
        p.join(
          flutter.path,
          'bin',
          'cache',
          'artifacts',
          'engine',
          'common',
          'flutter_patched_sdk',
        ),
      ).createSync(recursive: true);
      final runtime = testIPhoneRuntime();
      final compiler = FlutterKernelCompiler(
        runtime: runtime,
        registrant: DartPluginRegistrant(runtime.host.fileSystem),
        plugins: PluginDiscovery(runtime.host.fileSystem),
        projectRoot: flutter.path,
        flutterRoot: flutter.path,
      );
      const registration = 'file:///project/registrant.dart';
      final arguments = compiler.frontendServerArguments(
        compiler: const KernelCompiler(
          snapshot: '/frontend.snapshot',
          runtime: '/dart',
          runtimeName: 'dart',
          isAot: false,
        ),
        engineCache: runtime.engineCache(flutter.path),
        packageConfig: '/packages.json',
        outputDill: '/app.dill',
        entrypointArg: '/main.dart',
        dartPluginRegistrantUri: registration,
      );
      expect(
        arguments,
        containsAllInOrder([
          '--source',
          registration,
          '--source',
          'package:flutter/src/dart_plugin_registrant.dart',
          '-Dflutter.dart_plugin_registrant=$registration',
        ]),
      );
    });

    test('builds a file:// URI rather than a bare path', () {
      expect(
        FlutterKernelCompiler.dartPluginRegistrantUri(
          p.join(p.separator, 'proj', '.dart_tool', 'flutter_build', 'r.dart'),
          null,
        ),
        startsWith('file:///'),
      );
    });
  });
}
