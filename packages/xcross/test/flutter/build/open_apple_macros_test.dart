import 'dart:io';
import 'dart:isolate';

import 'package:cli_kit/composition/native_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/flutter/posix_toolchain_plugin_layout.dart';
import 'package:xcross/src/host/windows/flutter/windows_toolchain_plugin_layout.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/open_apple_macros.dart';

import '../../host_operations_fixtures.dart';
import 'support/fixture_swift_toolchain.dart';

void main() {
  final native = detectPlatformHost();
  late Directory root;
  late FixtureSwiftProcesses processes;
  late FixtureSwiftHost host;
  const driver = SwiftToolCommand('swiftc');
  const builder = SwiftToolCommand('swift', ['build']);
  String serverName() => native.paths.executableName(openAppleMacrosProduct);

  setUp(() {
    root = Directory.systemTemp.createTempSync('open-apple-macros-');
    processes = FixtureSwiftProcesses(
      native.paths,
      resourcePath: p.join(root.path, 'toolchain', 'usr', 'lib', 'swift'),
    );
    host = FixtureSwiftHost(native, processes);
  });
  tearDown(() => root.deleteSync(recursive: true));

  OpenAppleMacrosServer<FixtureSwiftHost> server({
    String? executable,
    String? launcher,
    String? configured,
  }) => OpenAppleMacrosServer(
    runner: fixtureRunner(host, log: fixtureLog()),
    layout: const PosixToolchainPluginLayout(),
    executable: executable ?? p.join(root.path, 'dart-sdk', 'bin', 'dart'),
    launcher: launcher,
    configured: configured,
  );

  Future<OpenAppleMacrosBuild> ensure(
    OpenAppleMacrosServer<FixtureSwiftHost> server,
  ) => server.ensure(
    cacheRoot: p.join(root.path, 'cache'),
    swiftDriver: driver,
    swiftBuild: builder,
  );

  File bundle(String prefix) =>
      File(p.join(root.path, prefix, 'lib', serverName()))
        ..createSync(recursive: true)
        ..writeAsStringSync('bundled');

  test('orders toolchain plugins before the server for Apple modules', () {
    const build = OpenAppleMacrosBuild(
      executable: '/cache/OpenAppleMacrosServer',
      toolchainPluginDirectory: '/toolchain/usr/lib/swift/host/plugins',
    );
    expect(build.swiftBuildArguments, [
      '-Xswiftc',
      '-plugin-path',
      '-Xswiftc',
      '/toolchain/usr/lib/swift/host/plugins',
      '-Xswiftc',
      '-load-plugin-executable',
      '-Xswiftc',
      '/cache/OpenAppleMacrosServer#FoundationModelsMacros,PreviewsMacros,SwiftUIMacros',
    ]);
  });

  test('derives the toolchain plugin directory per host layout', () {
    expect(
      const PosixToolchainPluginLayout().pluginDirectory(
        p.posix,
        '/opt/swift/usr/lib/swift',
      ),
      '/opt/swift/usr/lib/swift/host/plugins',
    );
    expect(
      const WindowsToolchainPluginLayout().pluginDirectory(
        p.windows,
        r'C:\Swift\Toolchains\6.4\usr\lib\swift',
      ),
      r'C:\Swift\Toolchains\6.4\usr\bin',
    );
  });

  test('uses the server bundled in lib/ beside the running xcross', () async {
    final bundled = bundle('install');
    final build = await ensure(
      server(executable: p.join(root.path, 'install', 'bin', 'xcross')),
    );
    expect(build.executable, bundled.path);
    expect(
      build.toolchainPluginDirectory,
      p.join(root.path, 'toolchain', 'usr', 'lib', 'swift', 'host', 'plugins'),
    );
    expect(processes.builds, 0);
    expect(processes.fetches, 0);
  });

  test('prefers the configured launcher bundle, then a configured path', () {
    final launcherServer = bundle('launcher');
    bundle('install');
    expect(
      server(
        executable: p.join(root.path, 'install', 'bin', 'xcross'),
        launcher: p.join(root.path, 'launcher', 'bin', 'xcross'),
      ).bundledServer(),
      launcherServer.path,
    );
    final configured = File(p.join(root.path, 'tools', serverName()))
      ..createSync(recursive: true);
    expect(
      server(
        launcher: p.join(root.path, 'launcher', 'bin', 'xcross'),
        configured: configured.path,
      ).bundledServer(),
      configured.path,
    );
    expect(
      () => server(configured: p.join(root.path, 'missing')).bundledServer(),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  test(
    'without a bundle, fetches the pinned revision and builds once',
    () async {
      final first = await ensure(server());
      expect(File(first.executable).readAsStringSync(), 'server-1');
      final fetch = processes.calls.firstWhere(
        (call) => call.contains('fetch'),
      );
      expect(fetch, containsAllInOrder([openAppleMacrosRevision]));
      final build = processes.calls.firstWhere(
        (call) => call.contains('--product'),
      );
      expect(build.take(2), ['swift', 'build']);
      expect(build, containsAllInOrder(['--configuration', 'release']));
      final second = await ensure(server());
      expect(second.executable, first.executable);
      expect(processes.builds, 1);
    },
  );

  test('toolchain identity invalidates the source build cache', () async {
    final first = await ensure(server());
    processes.compilerVersion = 'Swift version 6.5';
    final second = await ensure(server());
    expect(second.executable, isNot(first.executable));
    expect(processes.builds, 2);
  });

  test('rebuilds a tampered server and leaves no staging behind', () async {
    final first = await ensure(server());
    File(first.executable).writeAsStringSync('tampered');
    final second = await ensure(server());
    expect(second.executable, first.executable);
    expect(File(second.executable).readAsStringSync(), 'server-2');
    expect(
      Directory(p.dirname(first.executable))
          .listSync()
          .map((entity) => p.basename(entity.path))
          .where((name) => name.startsWith('publish-')),
      isEmpty,
    );
  });

  test('a failed build publishes nothing', () async {
    processes.buildExitCode = 3;
    await expectLater(ensure(server()), throwsA(anything));
    expect(
      Directory(p.join(root.path, 'cache', 'open-apple-macros'))
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => p.basename(file.path)),
      isNot(anyOf(contains('identity.json'), contains(serverName()))),
    );
  });

  test('pinned revision matches the third_party submodule', () async {
    final package = Isolate.resolvePackageUriSync(
      Uri.parse('package:xcross/'),
    )!;
    final repository = Directory.fromUri(package).parent.parent.parent.path;
    // The index records the gitlink commit the submodule is pinned to.
    final result = await Process.run('git', [
      'ls-files',
      '--stage',
      '--',
      'third_party/OpenAppleMacros',
    ], workingDirectory: repository);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      (result.stdout as String).trim().split(RegExp(r'\s+'))[1],
      openAppleMacrosRevision,
    );
  });

  test('module list matches the server umbrella in the submodule', () {
    final package = Isolate.resolvePackageUriSync(
      Uri.parse('package:xcross/'),
    )!;
    final umbrella = File(
      p.join(
        Directory.fromUri(package).parent.parent.parent.path,
        'third_party',
        'OpenAppleMacros',
        'Sources',
        'OpenAppleMacrosServer',
        'Generated',
        'All.swift',
      ),
    );
    if (!umbrella.existsSync()) {
      markTestSkipped('third_party/OpenAppleMacros is not checked out');
      return;
    }
    final served = RegExp(r'^\s*(\w+Macros)\.all,\s*$', multiLine: true)
        .allMatches(umbrella.readAsStringSync())
        .map((match) => match.group(1))
        .toSet();
    expect(served, containsAll(openAppleMacroModules));
  });
}
