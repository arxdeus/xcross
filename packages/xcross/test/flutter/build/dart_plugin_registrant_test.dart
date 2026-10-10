import 'dart:convert';
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
import 'package:xcross/src/shared/flutter/errors.dart';
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
        registrant: DartPluginRegistrant(fileSystem, host.paths.context),
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
              registrant: DartPluginRegistrant(fileSystem, paths),
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

  /// Copies the fixture [name] to [physicalRoot] and writes the
  /// `package_config.json` pub would, with package roots under [logicalRoot].
  String stageFixture(
    String name, {
    String? physicalRoot,
    String? logicalRoot,
    bool withGraph = true,
  }) {
    final physical = physicalRoot ?? p.join(tmp.path, name);
    final logical = logicalRoot ?? physical;
    final source = Directory(p.join(_fixturesRoot, name));
    for (final entity in source.listSync(recursive: true)) {
      if (entity is! File) continue;
      final target = File(
        p.join(physical, p.relative(entity.path, from: source.path)),
      );
      target.parent.createSync(recursive: true);
      entity.copySync(target.path);
    }
    final graph = File(p.join(physical, 'package_graph.json'));
    final names = [
      for (final package
          in (jsonDecode(graph.readAsStringSync()) as Map)['packages'] as List)
        (package as Map)['name'] as String,
    ];
    final app = names.first;
    final sdk = RegExp(r'sdk: \^(\d+\.\d+)').firstMatch(
      File(p.join(physical, 'app', 'pubspec.yaml')).readAsStringSync(),
    )!;
    final dartTool = Directory(p.join(physical, 'app', '.dart_tool'))
      ..createSync(recursive: true);
    if (withGraph) graph.copySync(p.join(dartTool.path, 'package_graph.json'));
    File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final package in names)
            {
              'name': package,
              'rootUri': package == app
                  ? '../'
                  : p.toUri(p.join(logical, 'packages', package)).toString(),
              'packageUri': 'lib/',
              'languageVersion': package == app ? sdk.group(1) : '3.4',
            },
        ],
      }),
    );
    File(p.join(physical, 'flutter', 'bin', 'cache', 'dart-sdk', 'version'))
      ..createSync(recursive: true)
      ..writeAsStringSync('3.13.0\n');
    return p.join(logical, 'app');
  }

  Future<String?> generate(
    String app, {
    HostFileSystemInterface? fileSystem,
    String entrypoint = 'lib/main.dart',
  }) => DartPluginRegistrant(fileSystem ?? LinuxHost().fileSystem, p.context)
      .generate(
        projectRoot: app,
        packageConfigPath: p.join(app, '.dart_tool', 'package_config.json'),
        entrypoint: p.join(app, entrypoint),
        flutterRoot: p.join(p.dirname(app), 'flutter'),
      );

  String golden(String name) => File(
    p.join(_fixturesRoot, name, 'flutter_tools_registrant.dart.golden'),
  ).readAsStringSync();

  group('generate matches flutter_tools 3.47 byte for byte', () {
    for (final withGraph in [true, false]) {
      final source = withGraph ? 'package_graph.json' : 'pubspecs';
      test('federated plugins resolved from $source', () async {
        final app = stageFixture('federated_registrant', withGraph: withGraph);
        final path = await generate(app);
        expect(path, DartPluginRegistrant.pathFor(app));
        expect(File(path!).readAsStringSync(), golden('federated_registrant'));
      });

      test('path_provider, shared_preferences and url_launcher app '
          'resolved from $source', () async {
        final app = stageFixture(
          'scratch_app_registrant',
          withGraph: withGraph,
        );
        expect(
          File((await generate(app))!).readAsStringSync(),
          golden('scratch_app_registrant'),
        );
      });
    }

    test('returns the logical path, not the filesystem I/O path', () async {
      final fileSystem = FixtureMappedFileSystem(tmp);
      final app = stageFixture(
        'scratch_app_registrant',
        physicalRoot: p.join(tmp.path, 'logical'),
        logicalRoot: '/logical',
      );
      final path = await generate(app, fileSystem: fileSystem);
      expect(path, DartPluginRegistrant.pathFor('/logical/app'));
      expect(
        File(fileSystem.physical(path!)).readAsStringSync(),
        golden('scratch_app_registrant'),
      );
    });
  });

  group('resolution errors match flutter_tools', () {
    test('a dev dependency is not a direct dependency', () async {
      final app = stageFixture('federated_registrant', withGraph: false);
      final pubspec = File(p.join(app, 'pubspec.yaml'));
      pubspec.writeAsStringSync(
        pubspec.readAsStringSync().replaceFirst(
          'dev_dependencies:',
          'dev_dependencies:\n  chooser_a:\n    path: ../packages/chooser_a',
        ),
      );
      expect(
        File((await generate(app))!).readAsStringSync(),
        golden('federated_registrant'),
      );
    });
    test('conflicting direct implementations', () async {
      final app = stageFixture('federated_registrant', withGraph: false);
      final pubspec = File(p.join(app, 'pubspec.yaml'));
      pubspec.writeAsStringSync(
        pubspec.readAsStringSync().replaceFirst(
          'dev_dependencies:',
          '  chooser_a:\n    path: ../packages/chooser_a\ndev_dependencies:',
        ),
      );
      await expectLater(
        generate(app),
        throwsA(
          isA<FlutterBuildError>().having(
            (e) => e.message,
            'message',
            'Plugin chooser:linux has conflicting direct dependency '
                'implementations:\n'
                '  chooser_b\n'
                '  chooser_a\n'
                '  chooser\n'
                'To fix this issue, remove all but one of these dependencies '
                'from pubspec.yaml.\n'
                'Please resolve the plugin implementation selection errors',
          ),
        ),
      );
    });

    test('inline implementation with a default package', () async {
      final app = stageFixture('federated_registrant');
      final pubspec = File(
        p.join(p.dirname(app), 'packages', 'fed', 'pubspec.yaml'),
      );
      pubspec.writeAsStringSync(
        pubspec.readAsStringSync().replaceFirst(
          'default_package: fed_ios',
          'default_package: fed_ios\n        dartPluginClass: FedSelf',
        ),
      );
      await expectLater(
        generate(app),
        throwsA(
          isA<FlutterBuildError>().having(
            (e) => e.message,
            'message',
            'Plugin fed:ios which provides an inline implementation cannot '
                'also reference a default implementation for fed_ios. Ask the '
                'maintainers of fed to either remove the implementation via '
                '`platforms: ios: dartPluginClass` or avoid referencing a '
                'default implementation via `platforms: ios: default_package: '
                'fed_ios`.\n'
                'Please resolve the plugin pubspec errors',
          ),
        ),
      );
    });
  });

  group('language version', () {
    test('falls back to the package, then the SDK', () async {
      final app = stageFixture('federated_registrant');
      File(p.join(app, 'lib', 'main.dart')).writeAsStringSync(
        '/* // @dart = 2.19 */\nimport "x.dart";\n// @dart = 2.12\n',
      );
      expect(
        File((await generate(app))!).readAsStringSync(),
        contains('''
// @dart = 3.6
'''),
      );
      expect(
        File(
          (await generate(app, entrypoint: 'lib/missing.dart'))!,
        ).readAsStringSync(),
        contains('// @dart = 3.13\n'),
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
      final source = DartPluginRegistrant.render(
        const {},
        languageVersion: '3.13',
      );
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
  });

  group('generate', () {
    test('removes a stale registrant when no plugin resolves', () async {
      final app = stageFixture('federated_registrant');
      final first = await generate(app);
      expect(File(first!).existsSync(), isTrue);

      File(
        p.join(app, 'pubspec.yaml'),
      ).writeAsStringSync('name: registrant_app\n');
      File(p.join(app, '.dart_tool', 'package_graph.json')).writeAsStringSync(
        jsonEncode({
          'configVersion': 1,
          'packages': [
            {'name': 'registrant_app', 'dependencies': <String>[]},
          ],
        }),
      );

      expect(await generate(app), isNull);
      expect(File(first).existsSync(), isFalse);
    });

    test('leaves an up-to-date registrant untouched', () async {
      final app = stageFixture('federated_registrant');
      final file = File((await generate(app))!);
      final stamp = DateTime(2000);
      file.setLastModifiedSync(stamp);
      await generate(app);
      expect(file.lastModifiedSync(), stamp);
    });
  });
}

String get _fixturesRoot => p.join(
  Directory.current.path.endsWith('xcross')
      ? Directory.current.path
      : p.join(Directory.current.path, 'packages', 'xcross'),
  'test',
  'flutter',
  'fixtures',
);

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
        registrant: DartPluginRegistrant(
          runtime.host.fileSystem,
          runtime.host.paths.context,
        ),
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
