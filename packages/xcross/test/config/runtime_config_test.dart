import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/config/posix_config_host.dart';
import 'package:xcross/src/host/windows/config/windows_config_host.dart';
import 'package:xcross/src/shared/config/config.dart';
import 'package:xcross/src/shared/config/runtime_config.dart';

import '../log_fixture.dart';

void main() {
  late Directory temporary;
  setUp(
    () => temporary = Directory.systemTemp.createTempSync(
      'xcross-runtime-config-',
    ),
  );
  tearDown(() => temporary.deleteSync(recursive: true));

  test('absent configuration preserves immutable legacy environment', () async {
    final host = LinuxHost(
      environment: const {'HOME': '/home/test', 'SECRET': 'visible'},
    );
    final runtime = await XcrossRuntimeConfig.load(
      host,
      configDirectory: temporary.path,
      policy: const PosixConfigHost(),
    );
    expect(runtime.isLegacy, isTrue);
    expect(runtime.config, isNull);
    expect(runtime.processConfiguration, isNull);
    expect(runtime.childEnvironment['SECRET'], 'visible');
    expect(
      () => runtime.childEnvironment['PATH'] = '/other',
      throwsUnsupportedError,
    );
  });

  test(
    'configuration prepends path and overlays roots without global state',
    () async {
      final host = LinuxHost(
        environment: const {
          'HOME': '/home/test',
          'PATH': '/usr/bin',
          'SECRET': 'inherited',
        },
      );
      File(p.join(temporary.path, 'config.yaml')).writeAsStringSync('''
roots:
  darwinSdk: /sdk
  flutterSdk: /flutter
  xcross: /bin/xcross
  javaHome: /java
  konanData: /konan
toolchains:
  swift: /swift/bin
  llvm: /llvm/bin
environment:
  PATH:
    - /tools
''');
      final runtime = await XcrossRuntimeConfig.load(
        host,
        configDirectory: temporary.path,
        policy: const PosixConfigHost(),
      );
      expect(runtime.isConfigured, isTrue);
      expect(runtime.roots!.darwinSdk, '/sdk');
      expect(runtime.childEnvironment['PATH'], '/tools:/usr/bin');
      expect(runtime.childEnvironment['JAVA_HOME'], '/java');
      expect(runtime.childEnvironment['KONAN_DATA_DIR'], '/konan');
      expect(runtime.childEnvironment['SECRET'], 'inherited');
      expect(
        runtime.childEnvironment['XCROSS_CONFIG'],
        p.join(temporary.path, 'config.yaml'),
      );
      expect(runtime.processConfiguration!.toolchainDirectories, {
        'swift': ['/swift/bin'],
        'llvm': ['/llvm/bin'],
      });
      final runner = ProcessRunner(
        host,
        log: testLog(),
        stdinStream: const Stream.empty(),
        stdoutSink: testByteSink(),
        stderrSink: testByteSink(),
        configuration: runtime.processConfiguration,
      );
      expect(runner.effectiveEnvironment, runtime.childEnvironment);
    },
  );

  test(
    'injected Windows overlay folds case and uses Windows separator on POSIX',
    () async {
      final fixtureHost = LinuxHost(currentDirectory: temporary.path);
      final host = WindowsHost(
        fileSystem: ConfigFixtureFileSystem(fixtureHost.fileSystem),
        environment: const {'Path': r'C:\Windows', 'JAVA_HOME': r'C:\old'},
      );
      final config = XcrossConfig(
        roots: const XcrossConfigRoots(javaHome: r'C:\java'),
        environment: {
          'PATH': <String>[r'C:\tools'],
        },
      );
      final store = XcrossConfigStore(
        host,
        directory: temporary.path,
        policy: const WindowsConfigHost(),
      );
      await store.save(config);
      final runtime = await XcrossRuntimeConfig.load(
        host,
        store: store,
        policy: const WindowsConfigHost(),
      );
      expect(runtime.childEnvironment['PATH'], r'C:\tools;C:\Windows');
      expect(runtime.childEnvironment, isNot(contains('Path')));
      expect(runtime.childEnvironment['JAVA_HOME'], r'C:\java');
    },
  );

  test('independent and concurrent loads do not share runtime state', () async {
    final first = LinuxHost(
      environment: const {'HOME': '/first', 'PATH': '/first/bin'},
    );
    final second = LinuxHost(
      environment: const {'HOME': '/second', 'PATH': '/second/bin'},
    );
    final loaded = await Future.wait([
      XcrossRuntimeConfig.load(
        first,
        configDirectory: temporary.path,
        policy: const PosixConfigHost(),
      ),
      XcrossRuntimeConfig.load(
        second,
        configDirectory: temporary.path,
        policy: const PosixConfigHost(),
      ),
    ]);
    expect(loaded[0], isNot(same(loaded[1])));
    expect(loaded[0].childEnvironment['PATH'], '/first/bin');
    expect(loaded[1].childEnvironment['PATH'], '/second/bin');
  });

  test('failed configuration load cannot poison another runtime', () async {
    final host = LinuxHost(environment: const {'HOME': '/home/test'});
    File(
      p.join(temporary.path, 'config.yaml'),
    ).writeAsStringSync('roots: [bad]');
    await expectLater(
      XcrossRuntimeConfig.load(
        host,
        configDirectory: temporary.path,
        policy: const PosixConfigHost(),
      ),
      throwsA(isA<XcrossConfigException>()),
    );
    File(p.join(temporary.path, 'config.yaml')).writeAsStringSync('roots: {}');
    final runtime = await XcrossRuntimeConfig.load(
      host,
      configDirectory: temporary.path,
      policy: const PosixConfigHost(),
    );
    expect(runtime.isConfigured, isTrue);
  });
}

final class ConfigFixtureFileSystem implements HostFileSystemInterface {
  const ConfigFixtureFileSystem(this.delegate);
  final HostFileSystemInterface delegate;
  String normalize(String path) => path.replaceAll(r'\', '/');
  @override
  File file(String path) => delegate.file(normalize(path));
  @override
  Directory directory(String path) => delegate.directory(normalize(path));
  @override
  Link link(String path) => delegate.link(normalize(path));
  @override
  void makeExecutable(String path) => delegate.makeExecutable(normalize(path));
  @override
  void setPermissions(String path, int mode) =>
      delegate.setPermissions(normalize(path), mode);
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      delegate.createArchiveLink(normalize(destination), normalize(target));
}
