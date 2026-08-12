import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/compose.dart';

void main() {
  test(
    'prepares isolated konan configuration with resolved Apple tool paths',
    () async {
      final fixture = _Fixture.create(ComposeHost.linuxX64)..createKotlinHome();
      final patched = <String>[];
      addTearDown(fixture.dispose);

      final prepared = await KonanConfiguration.withSeams(
        patchCompilerJar: (jar) async => patched.add(jar.path),
        makeExecutable: (_) {},
      ).prepare(project: fixture.project, toolchain: fixture.toolchain);

      final buildToolchain = p.join(
        fixture.root,
        'build',
        'xcross-ios',
        'toolchain',
      );
      expect(
        p.dirname(prepared.kotlinHome),
        startsWith('$buildToolchain${p.separator}'),
      );
      expect(p.basename(p.dirname(prepared.kotlinHome)), hasLength(64));
      expect(
        prepared.kotlinHome,
        p.join(p.dirname(prepared.kotlinHome), 'kotlin-home'),
      );
      expect(
        prepared.konanConfigPath,
        p.join(p.dirname(prepared.kotlinHome), 'konan', 'konan.properties'),
      );
      expect(prepared.environment['KONAN_DATA_DIR'], fixture.konanCache);
      expect(prepared.environment['JAVA_HOME'], fixture.javaHome);
      expect(
        prepared.environment['PATH'],
        startsWith('${p.join(p.dirname(prepared.kotlinHome), 'shims')}:'),
      );

      final config = File(prepared.konanConfigPath).readAsStringSync();
      expect(
        config,
        contains('targetSysRoot.ios_arm64=${_slash(fixture.sdk)}'),
      );
      expect(config, contains('linker.ios_arm64=${_slash(fixture.ld64)}'));
      expect(
        config,
        contains(
          'toolchainDependency.appleClang.ios_arm64=${_slash(fixture.clang)}',
        ),
      );
      expect(
        config,
        contains(
          'toolchainDependency.appleSwift.ios_arm64=${_slash(fixture.swiftc)}',
        ),
      );
      expect(config, isNot(contains(r'\\')));
      expect(config, isNot(contains('/tmp/uni')));
      expect(config, isNot(contains('/usr/bin/xcrun')));
      expect(config, isNot(contains('/usr/libexec/PlistBuddy')));

      expect(patched, hasLength(1));
      expect(patched.single, contains('.staging.'));
      expect(patched.single, isNot(startsWith(fixture.kotlinHome)));
      expect(
        File(
          p.join(
            prepared.kotlinHome,
            'konan',
            'lib',
            'kotlin-native-compiler-embeddable.jar',
          ),
        ).existsSync(),
        isTrue,
      );
      final compilerShim = File(prepared.konancExecutable).readAsStringSync();
      expect(compilerShim, contains('-Dkonan.home=${fixture.kotlinHome}'));
      expect(compilerShim, contains('KONAN_SHIM_HOME'));
      expect(
        compilerShim,
        contains('/konan/lib/kotlin-native-compiler-embeddable.jar'),
      );
      expect(compilerShim, isNot(contains('.staging.')));
      expect(compilerShim, isNot(contains('run_konan')));
      expect(
        File(
          p.join(fixture.kotlinHome, 'konan', 'konan.properties'),
        ).readAsStringSync(),
        'original=true\n',
      );
    },
  );

  test(
    'reuses completed fingerprint root without deleting or rebuilding it',
    () async {
      final fixture = _Fixture.create(ComposeHost.linuxX64)..createKotlinHome();
      final patched = <String>[];
      addTearDown(fixture.dispose);

      final configuration = KonanConfiguration.withSeams(
        patchCompilerJar: (jar) async => patched.add(jar.path),
        makeExecutable: (_) {},
      );
      final first = await configuration.prepare(
        project: fixture.project,
        toolchain: fixture.toolchain,
      );
      final sentinel = File(p.join(p.dirname(first.kotlinHome), 'sentinel.txt'))
        ..writeAsStringSync('keep');
      final second = await configuration.prepare(
        project: fixture.project,
        toolchain: fixture.toolchain,
      );

      expect(second.kotlinHome, first.kotlinHome);
      expect(second.konanConfigPath, first.konanConfigPath);
      expect(second.konancExecutable, first.konancExecutable);
      expect(sentinel.readAsStringSync(), 'keep');
      expect(patched, hasLength(1));
      expect(
        File(first.konanConfigPath).readAsStringSync(),
        contains(_slash(fixture.sdk)),
      );
    },
  );

  test(
    'overlapping prepares converge on one completed fingerprint root',
    () async {
      final fixture = _Fixture.create(ComposeHost.linuxX64)..createKotlinHome();
      final entered = Completer<void>();
      final release = Completer<void>();
      var patchCalls = 0;
      addTearDown(fixture.dispose);

      final configuration = KonanConfiguration.withSeams(
        patchCompilerJar: (jar) async {
          patchCalls += 1;
          if (!entered.isCompleted) entered.complete();
          await release.future;
        },
        makeExecutable: (_) {},
      );
      final firstFuture = configuration.prepare(
        project: fixture.project,
        toolchain: fixture.toolchain,
      );
      await entered.future;
      final secondFuture = configuration.prepare(
        project: fixture.project,
        toolchain: fixture.toolchain,
      );
      release.complete();
      final results = await Future.wait([firstFuture, secondFuture]);

      expect(results[1].kotlinHome, results[0].kotlinHome);
      expect(results[1].konanConfigPath, results[0].konanConfigPath);
      expect(results[1].konancExecutable, results[0].konancExecutable);
      expect(patchCalls, greaterThanOrEqualTo(1));
      expect(
        File(results[0].konanConfigPath).readAsStringSync(),
        contains(_slash(fixture.ld64)),
      );
      expect(
        File(results[0].konancExecutable).readAsStringSync(),
        contains('org.jetbrains.kotlin.cli.utilities.MainKt konanc'),
      );
      expect(
        Directory(p.join(fixture.root, 'build', 'xcross-ios', 'toolchain'))
            .listSync()
            .whereType<Directory>()
            .where((d) => p.basename(d.path).contains('staging')),
        isEmpty,
      );
    },
  );

  test('creates exact executable Linux shell shims', () async {
    final fixture = _Fixture.create(ComposeHost.linuxX64)..createKotlinHome();
    final executable = <String>{};
    addTearDown(fixture.dispose);

    final prepared = await KonanConfiguration.withSeams(
      patchCompilerJar: (_) async {},
      makeExecutable: executable.add,
    ).prepare(project: fixture.project, toolchain: fixture.toolchain);

    final shims = p.join(
      p.dirname(p.dirname(prepared.konanConfigPath)),
      'shims',
    );
    final xcrun = File(p.join(shims, 'xcrun'));
    expect(
      xcrun.readAsStringSync(),
      '#!/bin/sh\nexec "${_slash(fixture.clang)}" "\$@"\n',
    );
    expect(executable, everyElement(contains('.staging.')));
    if (!Platform.isWindows) {
      expect(xcrun.statSync().mode & 0x49, 0x49);
    }
  });

  test('creates Windows cmd shims and invokes them through cmd.exe', () async {
    final fixture = _Fixture.create(ComposeHost.windowsX64)..createKotlinHome();
    addTearDown(fixture.dispose);

    final prepared = await KonanConfiguration.withSeams(
      patchCompilerJar: (_) async {},
      makeExecutable: (_) {},
    ).prepare(project: fixture.project, toolchain: fixture.toolchain);

    final shims = p.join(p.dirname(prepared.kotlinHome), 'shims');
    final xcrun = File(p.join(shims, 'xcrun.cmd'));
    expect(xcrun.existsSync(), isTrue);
    expect(xcrun.readAsStringSync(), contains('cmd.exe /d /c'));
    final compilerShim = File(prepared.konancExecutable).readAsStringSync();
    expect(compilerShim, contains(_slash(fixture.javaHome)));
    expect(
      compilerShim,
      contains('-Dkonan.home=${_slash(fixture.kotlinHome)}'),
    );
    expect(compilerShim, contains(r'%KONAN_SHIM_HOME%\konan\lib'));
    expect(compilerShim, isNot(contains('.staging.')));
    expect(compilerShim, isNot(contains('run_konan')));
    expect(prepared.environment['PATH'], startsWith('$shims;'));
  });
}

String _slash(String value) => p.normalize(value).replaceAll(r'\\', '/');

final class _Fixture {
  _Fixture._(this.temp, this.host)
    : root = temp.path,
      modulePath = p.join(temp.path, 'shared'),
      kotlinHome = p.join(temp.path, 'global-kotlin'),
      konanCache = p.join(temp.path, 'konan-cache'),
      javaHome = p.join(temp.path, 'jdk'),
      sdk = p.join(temp.path, 'Apple SDKs', 'iPhoneOS.sdk'),
      ld64 = p.join(temp.path, 'toolchain', 'bin', 'ld64.lld'),
      clang = p.join(temp.path, 'toolchain', 'bin', 'clang'),
      swiftc = p.join(temp.path, 'toolchain', 'bin', 'swiftc');

  factory _Fixture.create(ComposeHost host) {
    final temp = Directory.systemTemp.createTempSync(
      'xcross_konan_config_test_',
    );
    return _Fixture._(temp, host);
  }

  final Directory temp;
  final ComposeHost host;
  final String root;
  final String modulePath;
  final String kotlinHome;
  final String konanCache;
  final String javaHome;
  final String sdk;
  final String ld64;
  final String clang;
  final String swiftc;

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
    host: host,
    kotlinHome: kotlinHome,
    konanCache: konanCache,
    konancExecutable: p.join(
      kotlinHome,
      'bin',
      host.isWindows ? 'konanc.bat' : 'konanc',
    ),
    javaHome: javaHome,
    javaExecutable: p.join(
      javaHome,
      'bin',
      host.isWindows ? 'java.exe' : 'java',
    ),
    gradleExecutable: host.isWindows ? 'gradle.bat' : 'gradle',
    swiftc: swiftc,
    clang: clang,
    ld64Lld: ld64,
    darwinSdkPath: sdk,
  );

  void createKotlinHome() {
    Directory(p.join(modulePath)).createSync(recursive: true);
    Directory(p.join(kotlinHome, 'bin')).createSync(recursive: true);
    Directory(p.join(kotlinHome, 'konan', 'lib')).createSync(recursive: true);
    File(
      p.join(kotlinHome, 'bin', host.isWindows ? 'konanc.bat' : 'konanc'),
    ).writeAsStringSync('konanc');
    File(
      p.join(kotlinHome, 'bin', host.isWindows ? 'run_konan.bat' : 'run_konan'),
    ).writeAsStringSync('run-konan');
    File(
      p.join(kotlinHome, 'konan', 'konan.properties'),
    ).writeAsStringSync('original=true\n');
    File(
      p.join(
        kotlinHome,
        'konan',
        'lib',
        'kotlin-native-compiler-embeddable.jar',
      ),
    ).writeAsStringSync('jar');
    Directory(sdk).createSync(recursive: true);
    Directory(p.dirname(ld64)).createSync(recursive: true);
    File(ld64).writeAsStringSync('ld64');
    File(clang).writeAsStringSync('clang');
    File(swiftc).writeAsStringSync('swiftc');
    Directory(javaHome).createSync(recursive: true);
    Directory(konanCache).createSync(recursive: true);
  }

  Future<void> dispose() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  }
}
