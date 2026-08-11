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
      expect(prepared.kotlinHome, p.join(buildToolchain, 'kotlin-home'));
      expect(
        prepared.konanConfigPath,
        p.join(buildToolchain, 'konan', 'konan.properties'),
      );
      expect(prepared.environment['KONAN_DATA_DIR'], fixture.konanCache);
      expect(prepared.environment['JAVA_HOME'], fixture.javaHome);
      expect(
        prepared.environment['PATH'],
        startsWith('${p.join(buildToolchain, 'shims')}:'),
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

      expect(patched, [
        p.join(
          prepared.kotlinHome,
          'konan',
          'lib',
          'kotlin-native-compiler-embeddable.jar',
        ),
      ]);
      expect(
        File(
          p.join(fixture.kotlinHome, 'konan', 'konan.properties'),
        ).readAsStringSync(),
        'original=true\n',
      );
    },
  );

  test('creates Windows cmd shims and invokes them through cmd.exe', () async {
    final fixture = _Fixture.create(ComposeHost.windowsX64)..createKotlinHome();
    addTearDown(fixture.dispose);

    final prepared = await KonanConfiguration.withSeams(
      patchCompilerJar: (_) async {},
      makeExecutable: (_) {},
    ).prepare(project: fixture.project, toolchain: fixture.toolchain);

    final shims = p.join(
      fixture.root,
      'build',
      'xcross-ios',
      'toolchain',
      'shims',
    );
    final xcrun = File(p.join(shims, 'xcrun.cmd'));
    expect(xcrun.existsSync(), isTrue);
    expect(xcrun.readAsStringSync(), contains('cmd.exe /d /c'));
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
