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
        parentEnvironment: const {
          'PATH': '/safe/path',
          'JAVA_OPTS': '-Dreviewer.path="value with spaces"',
          'JDK_JAVA_OPTIONS': '-Dexisting.option=true',
        },
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
      expect(prepared.environment['KONAN_USE_INTERNAL_SERVER'], '1');
      expect(
        prepared.environment['JDK_JAVA_OPTIONS'],
        '-Dexisting.option=true -Dreviewer.path="value with spaces"',
      );
      expect(
        prepared.environment['XCROSS_APPLE_TOOL_STRIP'],
        p.join(p.dirname(fixture.ld64), 'llvm-strip'),
      );
      expect(
        prepared.environment['XCROSS_APPLE_TOOL_DSYMUTIL'],
        p.join(p.dirname(fixture.ld64), 'dsymutil'),
      );
      expect(
        prepared.environment['XCROSS_APPLE_TOOL_LIBTOOL'],
        p.join(p.dirname(fixture.ld64), 'llvm-libtool-darwin'),
      );
      expect(
        prepared.environment['XCROSS_APPLE_TOOL_CLANGXX'],
        p.join(p.dirname(fixture.clang), 'clang++'),
      );
      expect(
        prepared.environment['PATH'],
        startsWith(
          '${p.join(p.dirname(prepared.kotlinHome), 'apple-toolchain', 'bin')}:',
        ),
      );
      // AppleConfigurablesImpl.getAbsoluteTargetToolchain() appends "/usr"
      // to the toolchain dir, and MacOSBasedLinker.compilerRtDir does
      // File("$absoluteTargetToolchain/lib/clang/").getListFiles(), which
      // throws NoSuchFileException (not an empty list) when the directory
      // is entirely absent. The compiler tolerates an empty directory (it
      // just means no compiler-rt library is provided at link time), so the
      // staged apple-toolchain must include an empty usr/lib/clang dir.
      expect(
        Directory(
          p.join(
            p.dirname(prepared.kotlinHome),
            'apple-toolchain',
            'usr',
            'lib',
            'clang',
          ),
        ).existsSync(),
        isTrue,
      );

      final config = File(prepared.konanConfigPath).readAsStringSync();
      expect(
        config,
        contains('targetSysRoot.ios_arm64=${_slash(fixture.sdk)}'),
      );
      expect(config, contains('targetToolchain.linux_x64-ios_arm64='));
      expect(config, contains('additionalToolsDir.linux_x64='));
      expect(config, contains('linker.linux_x64-ios_arm64='));
      // The patched HostManager reports every Apple KonanTarget as enabled,
      // so PlatformManager eagerly builds an AppleConfigurablesImpl for each
      // one at compiler startup (not just ios_arm64). Every Apple target
      // therefore needs a non-null targetSysRoot/targetToolchain override,
      // or the compiler throws a NullPointerException before konanc runs.
      for (final target in const [
        'macos_x64',
        'macos_arm64',
        'ios_arm64',
        'ios_x64',
        'ios_simulator_arm64',
        'tvos_arm64',
        'tvos_x64',
        'tvos_simulator_arm64',
        'watchos_arm32',
        'watchos_arm64',
        'watchos_device_arm64',
        'watchos_x64',
        'watchos_simulator_arm64',
      ]) {
        expect(
          config,
          contains('targetSysRoot.$target=${_slash(fixture.sdk)}'),
          reason: target,
        );
        expect(
          config,
          contains('targetToolchain.linux_x64-$target='),
          reason: target,
        );
        expect(
          prepared.konanPropertyOverrides,
          contains('targetSysRoot.$target='),
          reason: target,
        );
        expect(
          prepared.konanPropertyOverrides,
          contains('targetToolchain.linux_x64-$target='),
          reason: target,
        );
      }
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
      expect(prepared.javaExecutable, fixture.toolchain.javaExecutable);
      expect(
        prepared.compilerArguments,
        containsAllInOrder([
          '-Dkonan.home=${_slash(fixture.kotlinHome)}',
          '-cp',
          p.join(
            prepared.kotlinHome,
            'konan',
            'lib',
            'kotlin-native-compiler-embeddable.jar',
          ),
          'org.jetbrains.kotlin.cli.utilities.MainKt',
          'konanc',
        ]),
      );
      expect(prepared.compilerArguments.join(' '), isNot(contains('#!/bin')));
      expect(
        prepared.konanPropertyOverrides,
        contains('targetSysRoot.ios_arm64='),
      );
      expect(
        prepared.konanPropertyOverrides,
        contains('targetToolchain.linux_x64-ios_arm64='),
      );
      expect(
        prepared.konanPropertyOverrides,
        contains('additionalToolsDir.linux_x64='),
      );
      expect(
        prepared.konanPropertyOverrides,
        contains('linker.linux_x64-ios_arm64='),
      );
      expect(
        File(
          p.join(fixture.kotlinHome, 'konan', 'konan.properties'),
        ).readAsStringSync(),
        'original=true\n',
      );
    },
  );

  test(
    'stages real compiler-rt static libraries from the Darwin SDK bundle',
    () async {
      // MacOSBasedLinker.provideCompilerRtLibrary builds
      // "$compilerRtDir/libclang_rt.<platform>.a" and MacOSBasedLinker's
      // link step fails with "undefined symbol: __isPlatformVersionAtLeast"
      // (a symbol compiler-rt provides) unless that file is the real one
      // Xcode ships. Confirm KonanConfiguration copies it from the local
      // Darwin SDK artifact bundle's own Xcode toolchain rather than
      // leaving the staged directory empty.
      final fixture = _Fixture.create(ComposeHost.linuxX64)
        ..createKotlinHome()
        ..createCompilerRt();
      addTearDown(fixture.dispose);

      final prepared = await KonanConfiguration.withSeams(
        patchCompilerJar: (jar) async {},
        makeExecutable: (_) {},
      ).prepare(project: fixture.project, toolchain: fixture.toolchain);

      final stagedDarwin = p.join(
        p.dirname(prepared.kotlinHome),
        'apple-toolchain',
        'usr',
        'lib',
        'clang',
        'xcross',
        'lib',
        'darwin',
      );
      for (final name in const [
        'libclang_rt.ios.a',
        'libclang_rt.iossim.a',
        'libclang_rt.watchos.a',
        'libclang_rt.watchossim.a',
        'libclang_rt.tvos.a',
        'libclang_rt.tvossim.a',
        'libclang_rt.osx.a',
      ]) {
        final staged = File(p.join(stagedDarwin, name));
        expect(staged.existsSync(), isTrue, reason: name);
        expect(
          staged.readAsStringSync(),
          File(p.join(fixture.compilerRtDarwinDir, name)).readAsStringSync(),
          reason: name,
        );
      }
    },
  );

  test(
    'leaves compiler-rt directory empty when the Darwin SDK bundle has none',
    () async {
      // The fixture's darwinSdkBundle points at a directory that never gets
      // createCompilerRt() called on it, so _findCompilerRtDarwinDir can't
      // find an XcodeDefault.xctoolchain/usr/lib/clang/<version>/lib/darwin
      // under it. Confirm KonanConfiguration degrades to the pre-fix
      // behavior (an existing but empty clang dir) rather than throwing.
      final fixture = _Fixture.create(ComposeHost.linuxX64)..createKotlinHome();
      addTearDown(fixture.dispose);

      final prepared = await KonanConfiguration.withSeams(
        patchCompilerJar: (jar) async {},
        makeExecutable: (_) {},
      ).prepare(project: fixture.project, toolchain: fixture.toolchain);

      final clangDir = Directory(
        p.join(
          p.dirname(prepared.kotlinHome),
          'apple-toolchain',
          'usr',
          'lib',
          'clang',
        ),
      );
      expect(clangDir.existsSync(), isTrue);
      expect(clangDir.listSync(), isEmpty);
    },
  );

  test('picks the newest clang version directory deterministically when '
      'multiple exist', () async {
    // _findCompilerRtDarwinDir sorts candidate version directories rather
    // than trusting Directory.listSync()'s filesystem-dependent order, so
    // this must pick "21" over "19" regardless of listing order. A real
    // Xcode toolchain only ever ships one, so this only matters if that
    // ever changes, but a deterministic pick beats a flaky one either way.
    final fixture = _Fixture.create(ComposeHost.linuxX64)
      ..createKotlinHome()
      ..createCompilerRt();
    final olderDir = p.join(
      fixture.sdkBundle,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'clang',
      '19',
      'lib',
      'darwin',
    );
    Directory(olderDir).createSync(recursive: true);
    File(
      p.join(olderDir, 'libclang_rt.ios.a'),
    ).writeAsStringSync('WRONG-should-not-be-picked');
    addTearDown(fixture.dispose);

    final prepared = await KonanConfiguration.withSeams(
      patchCompilerJar: (jar) async {},
      makeExecutable: (_) {},
    ).prepare(project: fixture.project, toolchain: fixture.toolchain);

    final staged = File(
      p.join(
        p.dirname(prepared.kotlinHome),
        'apple-toolchain',
        'usr',
        'lib',
        'clang',
        'xcross',
        'lib',
        'darwin',
        'libclang_rt.ios.a',
      ),
    );
    expect(
      staged.readAsStringSync(),
      File(
        p.join(fixture.compilerRtDarwinDir, 'libclang_rt.ios.a'),
      ).readAsStringSync(),
    );
    expect(staged.readAsStringSync(), isNot(contains('WRONG')));
  });

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
      expect(second.compilerArguments, first.compilerArguments);
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
      expect(results[1].compilerArguments, results[0].compilerArguments);
      expect(patchCalls, greaterThanOrEqualTo(1));
      expect(
        File(results[0].konanConfigPath).readAsStringSync(),
        contains('/apple-toolchain/bin/ld'),
      );
      expect(
        results[0].compilerArguments,
        contains('org.jetbrains.kotlin.cli.utilities.MainKt'),
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

  test('creates safe executable Linux Apple tool aliases', () async {
    final fixture = _Fixture.create(ComposeHost.linuxX64)..createKotlinHome();
    final executable = <String>{};
    addTearDown(fixture.dispose);

    final prepared = await KonanConfiguration.withSeams(
      patchCompilerJar: (_) async {},
      makeExecutable: executable.add,
    ).prepare(project: fixture.project, toolchain: fixture.toolchain);

    final bin = p.join(
      p.dirname(prepared.kotlinHome),
      'apple-toolchain',
      'bin',
    );
    final ld = File(p.join(bin, 'ld'));
    expect(
      ld.readAsStringSync(),
      '#!/bin/sh\nexec "\$XCROSS_APPLE_TOOL_LD" "\$@"\n',
    );
    for (final name in [
      'ld',
      'strip',
      'dsymutil',
      'libtool',
      'clang',
      'clang++',
    ]) {
      expect(File(p.join(bin, name)).existsSync(), isTrue, reason: name);
    }
    expect(prepared.environment['XCROSS_APPLE_TOOL_LD'], fixture.ld64);
    expect(ld.readAsStringSync(), isNot(contains(fixture.ld64)));
    expect(executable, everyElement(contains('.staging.')));
    if (!Platform.isWindows) {
      expect(ld.statSync().mode & 0x49, 0x49);
    }

    // MacOSBasedLinker's constructor hardcodes linker/libtool/strip/dsymutil
    // as "$absoluteTargetToolchain/bin/<tool>", and
    // AppleConfigurables.getAbsoluteTargetToolchain() resolves to
    // "$appleToolchain/usr" (confirmed by decompiling the real compiler
    // jar), so those four tools must also exist under apple-toolchain's
    // usr/bin, not just bin. Without this, the linker step fails with
    // "Cannot run program ".../apple-toolchain/usr/bin/ld": No such file".
    final usrBin = p.join(
      p.dirname(prepared.kotlinHome),
      'apple-toolchain',
      'usr',
      'bin',
    );
    for (final name in ['ld', 'strip', 'dsymutil', 'libtool']) {
      expect(File(p.join(usrBin, name)).existsSync(), isTrue, reason: name);
    }
  });

  test('creates Windows native Apple tool aliases without cmd shims', () async {
    final fixture = _Fixture.create(ComposeHost.windowsX64)..createKotlinHome();
    final forwarder = File(p.join(fixture.root, 'xcross forwarder.exe'))
      ..writeAsStringSync('forwarder');
    addTearDown(fixture.dispose);

    final prepared = await KonanConfiguration.withSeams(
      patchCompilerJar: (_) async {},
      makeExecutable: (_) {},
      runningExecutable: forwarder.path,
    ).prepare(project: fixture.project, toolchain: fixture.toolchain);

    final bin = p.join(
      p.dirname(prepared.kotlinHome),
      'apple-toolchain',
      'bin',
    );
    for (final name in [
      'ld',
      'strip',
      'dsymutil',
      'libtool',
      'clang',
      'clang++',
    ]) {
      expect(
        File(p.join(bin, '$name.exe')).readAsStringSync(),
        'forwarder',
        reason: name,
      );
    }
    expect(
      Directory(bin).listSync().whereType<File>(),
      everyElement(
        isNot(predicate<File>((file) => file.path.endsWith('.cmd'))),
      ),
    );
    expect(
      prepared.konanPropertyOverrides,
      contains('targetToolchain.mingw_x64-ios_arm64='),
    );
    expect(
      prepared.konanPropertyOverrides,
      contains('additionalToolsDir.mingw_x64='),
    );
    expect(
      prepared.konanPropertyOverrides,
      contains('linker.mingw_x64-ios_arm64='),
    );
    expect(prepared.environment['PATH'], startsWith('$bin;'));

    // Same absoluteTargetToolchain/usr/bin requirement as Linux (see the
    // Linux test above): MacOSBasedLinker resolves linker/libtool/strip/
    // dsymutil relative to "$absoluteTargetToolchain/bin", which is
    // "$appleToolchain/usr/bin" once AppleConfigurables appends "/usr".
    final usrBin = p.join(
      p.dirname(prepared.kotlinHome),
      'apple-toolchain',
      'usr',
      'bin',
    );
    for (final name in ['ld', 'strip', 'dsymutil', 'libtool']) {
      expect(
        File(p.join(usrBin, '$name.exe')).existsSync(),
        isTrue,
        reason: name,
      );
    }
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
      sdkBundle = p.join(temp.path, 'Apple SDKs'),
      sdk = p.join(temp.path, 'Apple SDKs', 'iPhoneOS.sdk'),
      ld64 = p.join(temp.path, 'llvm', 'bin', 'ld64.lld'),
      clang = p.join(temp.path, 'swift', 'bin', 'clang'),
      swiftc = p.join(temp.path, 'swift', 'bin', 'swiftc');

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
  final String sdkBundle;
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
    darwinSdkBundle: sdkBundle,
  );

  /// The exact `.../usr/lib/clang/<version>/lib/darwin` layout Xcode ships
  /// compiler-rt static libraries in, so `_findCompilerRtDarwinDir` can find
  /// them under [sdkBundle] the same way it would under a real Darwin SDK
  /// artifact bundle.
  String get compilerRtDarwinDir => p.join(
    sdkBundle,
    'Developer',
    'Toolchains',
    'XcodeDefault.xctoolchain',
    'usr',
    'lib',
    'clang',
    '21',
    'lib',
    'darwin',
  );

  void createCompilerRt() {
    Directory(compilerRtDarwinDir).createSync(recursive: true);
    for (final name in const [
      'libclang_rt.ios.a',
      'libclang_rt.iossim.a',
      'libclang_rt.watchos.a',
      'libclang_rt.watchossim.a',
      'libclang_rt.tvos.a',
      'libclang_rt.tvossim.a',
      'libclang_rt.osx.a',
    ]) {
      File(
        p.join(compilerRtDarwinDir, name),
      ).writeAsStringSync('fake-compiler-rt-$name');
    }
  }

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
    Directory(p.dirname(clang)).createSync(recursive: true);
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
