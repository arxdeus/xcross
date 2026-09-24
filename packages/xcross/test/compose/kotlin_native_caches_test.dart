import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/compose.dart';
import 'package:xcross/src/errors.dart';

void main() {
  group('parseJavaProperties', () {
    test('unescapes keys and values the way klib manifests write them', () {
      final properties = parseJavaProperties(
        [
          '# comment',
          '! also a comment',
          r'unique_name=org.jetbrains.kotlinx\:kotlinx-io-core',
          'depends=stdlib org.jetbrains.kotlin.native.platform.Foundation',
          r'spaced\ key : value with spaces',
          r'wrapped=first \',
          '    second',
          r'tab=a\tb',
        ].join('\n'),
      );

      expect(
        properties['unique_name'],
        'org.jetbrains.kotlinx:kotlinx-io-core',
      );
      expect(
        properties['depends'],
        'stdlib org.jetbrains.kotlin.native.platform.Foundation',
      );
      expect(properties['spaced key'], 'value with spaces');
      expect(properties['wrapped'], 'first second');
      expect(properties['tab'], 'a\tb');
      expect(properties, hasLength(5));
    });
  });

  group('readKlibManifest', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('xcross_klib_'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('reads an unpacked klib in the default/ layout', () {
      final klib = _unpackedKlib(temp.path, 'core', 'project:core', const []);
      expect(readKlibManifest(klib)['unique_name'], 'project:core');
    });

    test('reads a packed .klib without needing the rest of it', () {
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'default/manifest',
            utf8.encode(
              r'unique_name=org.example\:packed'
              '\n',
            ),
          ),
        )
        ..addFile(ArchiveFile.bytes('default/ir/bodies.knb', [1, 2, 3]));
      final klib = File(p.join(temp.path, 'packed.klib'))
        ..writeAsBytesSync(ZipEncoder().encode(archive));

      expect(readKlibManifest(klib.path)['unique_name'], 'org.example:packed');
    });

    test('fails loudly for something that is not a klib', () {
      final dir = Directory(p.join(temp.path, 'nothing'))..createSync();
      expect(() => readKlibManifest(dir.path), throwsA(isA<XcrossError>()));
    });
  });

  group('KotlinNativeCaches', () {
    late _Fixture fixture;
    setUp(() => fixture = _Fixture.create());
    tearDown(() => fixture.dispose());

    test('plans every library in dependency order, stdlib first', () {
      final plan = fixture.plan();
      final names = plan.libraries.map((node) => node.uniqueName).toList();

      expect(names, hasLength(5));
      expect(names.first, 'stdlib');
      for (final node in plan.libraries) {
        for (final dependency in node.dependencies) {
          expect(
            names.indexOf(dependency),
            lessThan(names.indexOf(node.uniqueName)),
            reason: '${node.uniqueName} needs $dependency cached first',
          );
        }
      }
      // Platform libraries are pulled in from the module's own manifest too,
      // not only from dependencies' manifests.
      expect(names, contains('org.jetbrains.kotlin.native.platform.UIKit'));
      final byName = {for (final node in plan.libraries) node.uniqueName: node};
      expect(byName['stdlib']!.fromDistribution, isTrue);
      expect(
        byName['org.jetbrains.kotlin.native.platform.Foundation']!
            .fromDistribution,
        isTrue,
      );
      expect(byName['org.example:lib-a']!.fromDistribution, isFalse);
      expect(
        byName['org.example:lib-b']!.cachePath,
        p.join(
          byName['org.example:lib-b']!.cacheRoot,
          'org.example:lib-b-cache',
        ),
      );
      expect(
        plan.moduleCacheRoot,
        p.join(
          fixture.root,
          'build',
          'xcross-ios',
          'konan-caches',
          'module-shared',
        ),
      );
      expect(
        plan.linkArguments.last,
        '-Xcache-directory=${plan.moduleCacheRoot}',
      );
      expect(plan.linkArguments, hasLength(6));
    });

    test('a changed library re-keys it and everything built on it', () {
      final before = fixture.cacheRoots();
      // lib-a is a directory klib, the shape Gradle rewrites in place.
      File(p.join(fixture.libA, 'default', 'ir', 'bodies.knb'))
        ..writeAsStringSync('changed and longer')
        ..setLastModifiedSync(DateTime(2030));
      final after = fixture.cacheRoots();

      expect(after['stdlib'], before['stdlib']);
      expect(
        after['org.jetbrains.kotlin.native.platform.Foundation'],
        before['org.jetbrains.kotlin.native.platform.Foundation'],
      );
      expect(after['org.example:lib-a'], isNot(before['org.example:lib-a']));
      expect(after['org.example:lib-b'], isNot(before['org.example:lib-b']));
    });

    test('builds each cache once, then only the module per-file cache', () async {
      final plan = fixture.plan();
      final calls = <List<String>>[];

      Future<void> build() => const KotlinNativeCaches(jobs: 2).build(
        plan: plan,
        prepared: fixture.prepared,
        klib: fixture.klib,
        workingDirectory: fixture.root,
        run:
            (
              executable,
              arguments, {
              required workingDirectory,
              required environment,
            }) async {
              expect(executable, fixture.prepared.javaExecutable);
              expect(environment, fixture.prepared.environment);
              expect(workingDirectory, fixture.root);
              calls.add(arguments);
              _produceCache(arguments, plan);
            },
      );

      await build();
      expect(calls, hasLength(6), reason: 'five libraries and the module');

      final built = [
        for (final call in calls.take(5))
          call.firstWhere((a) => a.startsWith('-Xadd-cache=')).substring(12),
      ];
      final order = plan.libraries.map((node) => node.path).toList();
      for (final node in plan.libraries) {
        for (final dependency in node.dependencies) {
          final dependencyPath = plan.libraries
              .firstWhere((other) => other.uniqueName == dependency)
              .path;
          expect(
            built.indexOf(dependencyPath),
            lessThan(built.indexOf(node.path)),
          );
        }
      }
      expect(built.toSet(), order.toSet());

      final libB = calls.firstWhere(
        (call) => call.contains('-Xadd-cache=${fixture.libB}'),
      );
      expect(libB, containsAllInOrder(['-p', 'static_cache']));
      expect(libB, contains('-Xbinary=enableDebugTransparentStepping=false'));
      expect(libB, containsAllInOrder(['-target', 'ios_arm64']));
      expect(
        libB,
        contains(
          '-Xoverride-konan-properties=${fixture.prepared.konanPropertyOverrides}',
        ),
      );
      // Its project dependency is passed as a library and as a cache; the
      // distribution's own libraries only as caches.
      expect(libB, containsAllInOrder(['-library', fixture.libA]));
      expect(libB.where((a) => a == '-library'), hasLength(1));
      final byName = {for (final node in plan.libraries) node.uniqueName: node};
      for (final name in [
        'stdlib',
        'org.jetbrains.kotlin.native.platform.Foundation',
        'org.example:lib-a',
      ]) {
        expect(
          libB,
          contains(
            '-Xcached-library=${byName[name]!.path},${byName[name]!.cachePath}',
          ),
        );
      }

      final module = calls.last;
      expect(module, contains('-Xadd-cache=${fixture.moduleKlib}'));
      expect(module, contains('-Xmake-per-file-cache'));
      expect(module, contains('-Xcache-directory=${plan.moduleCacheRoot}'));
      expect(
        module,
        containsAllInOrder([
          '-library',
          fixture.libA,
          '-library',
          fixture.libB,
        ]),
      );
      for (final node in plan.libraries) {
        expect(module, contains('-Xcache-directory=${node.cacheRoot}'));
        expect(
          File(p.join(node.cacheRoot, '.xcross-complete')).existsSync(),
          isTrue,
        );
      }

      calls.clear();
      await build();
      expect(calls, hasLength(1));
      expect(calls.single, contains('-Xmake-per-file-cache'));
    });

    test('says how to opt out when a cache is not produced', () async {
      final plan = fixture.plan();
      await expectLater(
        const KotlinNativeCaches(jobs: 1).build(
          plan: plan,
          prepared: fixture.prepared,
          klib: fixture.klib,
          workingDirectory: fixture.root,
          run:
              (
                executable,
                arguments, {
                required workingDirectory,
                required environment,
              }) async {},
        ),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.toString(),
            'message',
            contains(KotlinNativeCaches.disableVariable),
          ),
        ),
      );
      expect(
        Directory(plan.libraries.first.cacheRoot).existsSync(),
        isFalse,
        reason: 'a failed build must not leave a cache that looks complete',
      );
    });

    test('is on unless XCROSS_NO_KONAN_CACHE=1', () {
      expect(KotlinNativeCaches.enabledIn(const {}), isTrue);
      expect(
        KotlinNativeCaches.enabledIn(const {'XCROSS_NO_KONAN_CACHE': '0'}),
        isTrue,
      );
      expect(
        KotlinNativeCaches.enabledIn(const {'XCROSS_NO_KONAN_CACHE': '1'}),
        isFalse,
      );
    });

    test(
      'debug framework links against the caches, release does not',
      () async {
        final calls = <List<String>>[];
        Future<void> link(ComposeConfiguration configuration) =>
            KotlinFrameworkBuilder.withSeams(
              runChecked:
                  (
                    executable,
                    arguments, {
                    workingDirectory,
                    environment,
                  }) async {
                    calls.add(arguments);
                    if (arguments.contains('-p')) {
                      _produceCache(arguments, fixture.plan());
                      return;
                    }
                    final framework = p.join(
                      fixture.modulePath,
                      'build',
                      'bin',
                      'iosArm64',
                      '${configuration.name}Framework',
                      'Shared.framework',
                    );
                    Directory(
                      p.join(framework, 'Headers'),
                    ).createSync(recursive: true);
                    File(
                      p.join(framework, 'Shared'),
                    ).writeAsStringSync('binary');
                    File(
                      p.join(framework, 'Headers', 'Shared.h'),
                    ).writeAsStringSync('h');
                  },
              prepareKonan: ({required project, required toolchain}) async =>
                  fixture.prepared,
              caches: const KotlinNativeCaches(jobs: 1),
            ).build(
              project: fixture.project,
              options: ComposeBuildOptions(configuration: configuration),
              toolchain: fixture.toolchain,
              klib: fixture.klib,
            );

        await link(ComposeConfiguration.debug);
        expect(
          calls,
          hasLength(7),
          reason: 'five caches, the module, the link',
        );
        expect(calls.last, containsAllInOrder(['-produce', 'framework']));
        for (final argument in fixture.plan().linkArguments) {
          expect(calls.last, contains(argument));
        }

        calls.clear();
        await link(ComposeConfiguration.release);
        expect(calls, hasLength(1));
        expect(calls.single, contains('-opt'));
        expect(
          calls.single.where((a) => a.startsWith('-Xcache-directory=')),
          isEmpty,
        );
      },
    );
  });
}

/// Does what konanc does for a `-p static_cache` call: writes
/// `<cache directory>/<unique name>-cache`.
void _produceCache(List<String> arguments, KotlinNativeCachePlan plan) {
  final added = arguments
      .firstWhere((a) => a.startsWith('-Xadd-cache='))
      .substring('-Xadd-cache='.length);
  final output = arguments
      .firstWhere((a) => a.startsWith('-Xcache-directory='))
      .substring('-Xcache-directory='.length);
  final name = plan.libraries
      .where((node) => node.path == added)
      .map((node) => node.uniqueName)
      .firstOrNull;
  Directory(
    p.join(output, '${name ?? 'shared'}-cache'),
  ).createSync(recursive: true);
}

String _unpackedKlib(
  String parent,
  String dirName,
  String uniqueName,
  List<String> depends,
) {
  final dir = p.join(parent, dirName);
  Directory(p.join(dir, 'default', 'ir')).createSync(recursive: true);
  File(p.join(dir, 'default', 'manifest')).writeAsStringSync(
    'unique_name=${uniqueName.replaceAll(':', r'\:')}\n'
    'depends=${depends.join(' ')}\n',
  );
  File(p.join(dir, 'default', 'ir', 'bodies.knb')).writeAsStringSync(dirName);
  return dir;
}

final class _Fixture {
  _Fixture._(this.temp);

  factory _Fixture.create() {
    final fixture = _Fixture._(
      Directory.systemTemp.createTempSync('xcross_konan_caches_'),
    );
    final home = fixture.kotlinHome;
    _unpackedKlib(p.join(home, 'klib', 'common'), 'stdlib', 'stdlib', const []);
    final platform = p.join(home, 'klib', 'platform', 'ios_arm64');
    _unpackedKlib(
      platform,
      'org.jetbrains.kotlin.native.platform.Foundation',
      'org.jetbrains.kotlin.native.platform.Foundation',
      const ['stdlib'],
    );
    _unpackedKlib(
      platform,
      'org.jetbrains.kotlin.native.platform.UIKit',
      'org.jetbrains.kotlin.native.platform.UIKit',
      const ['stdlib', 'org.jetbrains.kotlin.native.platform.Foundation'],
    );
    // A platform library nothing uses must stay out of the plan.
    _unpackedKlib(
      platform,
      'org.jetbrains.kotlin.native.platform.Metal',
      'org.jetbrains.kotlin.native.platform.Metal',
      const ['stdlib'],
    );
    _unpackedKlib(fixture.deps, 'lib-a', 'org.example:lib-a', const [
      'stdlib',
      'org.jetbrains.kotlin.native.platform.Foundation',
    ]);
    // lib-b lists a dependency that no library provides; it is skipped.
    _unpackedKlib(fixture.deps, 'lib-b', 'org.example:lib-b', const [
      'stdlib',
      'org.example:lib-a',
      'org.example:not-on-the-classpath',
    ]);
    _unpackedKlib(
      p.join(
        fixture.modulePath,
        'build',
        'classes',
        'kotlin',
        'iosArm64',
        'main',
        'klib',
      ),
      'shared',
      'project:shared',
      const [
        'stdlib',
        'org.example:lib-b',
        'org.jetbrains.kotlin.native.platform.UIKit',
      ],
    );
    return fixture;
  }

  final Directory temp;

  String get root => p.join(temp.path, 'project');
  String get modulePath => p.join(root, 'shared');
  String get kotlinHome => p.join(temp.path, 'kotlin-native');
  String get deps => p.join(temp.path, 'deps');
  String get libA => p.join(deps, 'lib-a');
  String get libB => p.join(deps, 'lib-b');
  String get moduleKlib => p.join(
    modulePath,
    'build',
    'classes',
    'kotlin',
    'iosArm64',
    'main',
    'klib',
    'shared',
  );

  GradleKlibResult get klib =>
      GradleKlibResult(moduleKlibPath: moduleKlib, dependencies: [libA, libB]);

  KmpProject get project => KmpProject(
    root: root,
    modulePath: modulePath,
    moduleName: 'shared',
    baseName: 'Shared',
    entryKind: KmpEntryKind.frameworkOnly,
    bundleId: 'dev.example.shared',
    appName: 'Example',
  );

  ComposeToolchain get toolchain => ComposeToolchain(
    host: ComposeHost.linuxX64,
    kotlinHome: kotlinHome,
    konanCache: p.join(temp.path, 'konan-cache'),
    konancExecutable: p.join(kotlinHome, 'bin', 'konanc'),
    javaHome: p.join(temp.path, 'jdk'),
    javaExecutable: p.join(temp.path, 'jdk', 'bin', 'java'),
    gradleExecutable: 'gradle',
    swiftc: 'swiftc',
    clang: 'clang',
    ld64Lld: 'ld64.lld',
    darwinSdkPath: 'sdk',
    darwinSdkBundle: 'bundle',
  );

  PreparedKonanConfiguration get prepared => PreparedKonanConfiguration(
    kotlinHome: p.join(
      root,
      'build',
      'xcross-ios',
      'toolchain',
      'abc123',
      'kotlin-home',
    ),
    konanConfigPath: 'konan.properties',
    javaExecutable: p.join(temp.path, 'jdk', 'bin', 'java'),
    compilerArguments: const ['-cp', 'compiler.jar', 'Main', 'konanc'],
    konanPropertyOverrides: 'cacheableTargets.linux_x64=ios_arm64',
    environment: const {'KONAN_USE_INTERNAL_SERVER': '1'},
  );

  KotlinNativeCachePlan plan() => const KotlinNativeCaches().plan(
    project: project,
    toolchain: toolchain,
    prepared: prepared,
    klib: klib,
  )!;

  Map<String, String> cacheRoots() => {
    for (final node in plan().libraries) node.uniqueName: node.cacheRoot,
  };

  void dispose() => temp.deleteSync(recursive: true);
}
