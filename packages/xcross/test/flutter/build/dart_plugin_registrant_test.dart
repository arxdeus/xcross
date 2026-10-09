import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/shared/posix_paths.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/dart_plugin_registrant.dart';
import 'package:xcross/src/shared/flutter/build/internal/kernel_compiler.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugins.dart';
import 'package:xcross/src/shared/flutter/flutter_kernel_compiler.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';

import '../../host_operations_fixtures.dart';
import '../flutter_test_runtime.dart';

void main() {
  _frontendServerFlags();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_dart_registrant-');
  });

  tearDown(() => tmp.delete(recursive: true));

  test(
    'kernel package URI loader retains selected filesystem and namespace',
    () async {
      final fileSystem = FixtureMappedFileSystem(tmp);
      final host = LinuxHost(
        fileSystem: fileSystem,
        currentDirectory: '/selected-kernel-project',
        temporaryDirectory: '/selected-kernel-temp',
      );
      final runtime = testFlutterRuntime(
        IPhoneFlutterTarget(IPhoneTarget(host)),
      );
      const configPath =
          '/selected-kernel-project/.dart_tool/package_config.json';
      fileSystem.file(configPath)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '{"configVersion":2,"packages":[{"name":"mapped","rootUri":"../","packageUri":"lib/"}]}',
        );
      final compiler = FlutterKernelCompiler(
        runtime: runtime,
        registrant: DartPluginRegistrant(fileSystem),
        plugins: PluginDiscovery(fileSystem),
        projectRoot: '/selected-kernel-project',
        flutterRoot: '/unused',
      );
      expect(compiler.packageUriLoader.fileSystem, same(fileSystem));
      expect(compiler.packageUriLoader.paths, same(host.paths.context));
      fileSystem.touched.clear();
      final packageUris = await compiler.packageUriLoader.load(configPath);
      expect(
        packageUris?.toCompilerUri('/selected-kernel-project/lib/main.dart'),
        'package:mapped/main.dart',
      );
      expect(fileSystem.touched, contains(configPath));
    },
  );

  for (final projectRoot in [
    r'C:\selected project',
    r'\\server\share\selected project',
  ]) {
    test(
      'kernel entrypoint and registrant preserve selected namespace $projectRoot',
      () async {
        final paths = p.Context(style: p.Style.windows, current: projectRoot);
        final fileSystem = KernelNamespaceFileSystem(tmp);
        final host = LinuxHost(
          fileSystem: fileSystem,
          paths: PosixPaths(
            context: paths,
            currentDirectory: projectRoot,
            temporaryDirectory: paths.join(projectRoot, 'tmp'),
          ),
        );
        final runtime = testFlutterRuntime(
          IPhoneFlutterTarget(IPhoneTarget(host)),
        );
        final configPath = paths.join(
          projectRoot,
          '.dart_tool',
          'package_config.json',
        );
        fileSystem.file(configPath)
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '{"configVersion":2,"packages":[{"name":"mapped","rootUri":"../","packageUri":"lib/"}]}',
          );
        FlutterKernelCompiler<LinuxHost> compiler(String entrypoint) =>
            FlutterKernelCompiler(
              runtime: runtime,
              registrant: DartPluginRegistrant(fileSystem),
              plugins: PluginDiscovery(fileSystem),
              projectRoot: projectRoot,
              flutterRoot: paths.join(projectRoot, 'flutter'),
              entrypoint: entrypoint,
            );
        expect(
          await compiler(
            paths.join(projectRoot, 'lib', 'main.dart'),
          ).resolveEntrypointArg(configPath),
          'package:mapped/main.dart',
        );
        expect(
          await compiler(r'lib\main.dart').resolveEntrypointArg(configPath),
          'package:mapped/main.dart',
        );
        final packageUris = await compiler(
          'unused',
        ).packageUriLoader.load(configPath);
        final registrant = paths.join(
          projectRoot,
          '.dart_tool',
          'flutter_build',
          'registrant.dart',
        );
        expect(
          FlutterKernelCompiler.dartPluginRegistrantUri(
            registrant,
            packageUris,
            paths: paths,
          ),
          paths.toUri(registrant).toString(),
        );
        expect(
          FlutterKernelCompiler.dartPluginRegistrantUri(
            paths.join(projectRoot, 'lib', 'registrant.dart'),
            packageUris,
            paths: paths,
          ),
          'package:mapped/registrant.dart',
        );
        expect(fileSystem.touched, contains(configPath));
      },
    );
  }

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
    List<(String, int)> directivePolicy(String source) {
      final unit = parseString(content: source, throwIfDiagnostics: false).unit;
      return [
        for (final directive in unit.directives) ...[
          if (directive is ExportDirective)
            ('export-directive', directive.offset),
          if (directive is NamespaceDirective)
            for (final combinator in directive.combinators)
              if (combinator is ShowCombinator)
                ('show-combinator', combinator.offset)
              else if (combinator is HideCombinator)
                ('hide-combinator', combinator.offset),
        ],
      ];
    }

    test('AST directive policy preserves exact external VM protocol', () {
      final source = DartPluginRegistrant.render(const []);
      expect(directivePolicy(source), isEmpty);
      final unit = parseString(content: source).unit;
      expect(
        unit.declarations
            .whereType<ClassDeclaration>()
            .single
            .namePart
            .typeName
            .lexeme,
        '_PluginRegistrant',
      );
      expect(source, contains("@pragma('vm:entry-point')"));
      expect(
        directivePolicy(
          '$source\n// export ignored;\nconst text = "import show hide export";',
        ),
        isEmpty,
      );
      final exported = "export 'missing.dart';\n$source";
      expect(directivePolicy(exported), [('export-directive', 0)]);
      for (final combinator in ['show', 'hide']) {
        final filtered = source.replaceFirst(
          "import 'dart:io';",
          "import 'dart:io' $combinator Platform;",
        );
        expect(directivePolicy(filtered), [
          ('$combinator-combinator', filtered.indexOf(combinator)),
        ]);
      }
    });

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

    test('returns the logical path, not the filesystem I/O path', () async {
      final fileSystem = FixtureMappedFileSystem(tmp);
      final path = await DartPluginRegistrant(fileSystem).generate(
        projectRoot: '/logical-project',
        plugins: [writePlugin('plugin_b', dartPluginClass: 'PluginB')],
      );

      expect(path, DartPluginRegistrant.pathFor('/logical-project'));
      expect(
        File(fileSystem.physical(path!)).readAsStringSync(),
        contains('plugin_b.PluginB.registerWith();'),
      );
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
          paths: p.Context(style: p.Style.posix),
        ),
        startsWith('file:///'),
      );
    });
  });
}

@internal
final class KernelNamespaceFileSystem implements HostFileSystemInterface {
  KernelNamespaceFileSystem(this.root);
  final Directory root;
  final List<String> touched = [];
  String physical(String path) {
    if (path == root.path || p.isWithin(root.path, path)) return path;
    return p.join(
      root.path,
      path
          .replaceAll(r'\', '/')
          .replaceAll(':', '')
          .replaceFirst(RegExp('^/+'), ''),
    );
  }

  @override
  File file(String path) {
    touched.add(path);
    return File(physical(path));
  }

  @override
  Directory directory(String path) => Directory(physical(path));
  @override
  Link link(String path) => Link(physical(path));
  @override
  void makeExecutable(String path) {}
  @override
  void setPermissions(String path, int mode) {}
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      link(destination).create(target);
}
