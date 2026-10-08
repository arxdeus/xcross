import 'dart:io';

import 'package:cli_kit/composition/native_host.dart';
import 'package:cli_kit/shared/errors/errors.dart';
import 'package:open_apple_macros/host/shared/posix_toolchain_plugin_layout.dart';
import 'package:open_apple_macros/host/windows/windows_toolchain_plugin_layout.dart';
import 'package:open_apple_macros/shared/open_apple_macros_server.dart';
import 'package:open_apple_macros/src/shared/open_apple_macros_sources.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture_swift_toolchain.dart';

void main() {
  final native = detectPlatformHost();
  late Directory root;
  late FixtureSwiftProcesses processes;
  late OpenAppleMacrosServer<FixtureHost> server;
  const driver = SwiftToolCommand('swiftc');
  const builder = SwiftToolCommand('swift', ['build']);

  setUp(() {
    root = Directory.systemTemp.createTempSync('open-apple-macros-');
    processes = FixtureSwiftProcesses(
      native.paths,
      resourcePath: p.join(root.path, 'toolchain', 'usr', 'lib', 'swift'),
    );
    server = OpenAppleMacrosServer(
      runner: fixtureRunner(FixtureHost(native, processes)),
      layout: const PosixToolchainPluginLayout(),
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<OpenAppleMacrosBuild> ensure() => server.ensure(
    cacheRoot: root.path,
    swiftDriver: driver,
    swiftBuild: builder,
  );

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
    expect(
      build.swiftcArguments.indexOf('-plugin-path'),
      lessThan(build.swiftcArguments.indexOf('-load-plugin-executable')),
    );
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
        r'C:\Swift\Toolchains\6.3\usr\lib\swift',
      ),
      r'C:\Swift\Toolchains\6.3\usr\bin',
    );
  });

  test('builds once in debug and reuses the published server', () async {
    final first = await ensure();
    expect(File(first.executable).readAsStringSync(), 'server-1');
    expect(
      first.toolchainPluginDirectory,
      p.join(root.path, 'toolchain', 'usr', 'lib', 'swift', 'host', 'plugins'),
    );
    final build = processes.calls.firstWhere(
      (call) => call.contains('--product'),
    );
    expect(build.take(2), ['swift', 'build']);
    expect(build, containsAllInOrder(['--configuration', 'debug']));
    expect(build, contains('--scratch-path'));
    expect(
      File(
        p.join(p.dirname(first.executable), 'src', 'Package.swift'),
      ).readAsStringSync(),
      sourcePackageSwift,
    );
    final second = await ensure();
    expect(second.executable, first.executable);
    expect(processes.builds, 1);
  });

  test('toolchain identity and sources invalidate the cache', () async {
    final first = await ensure();
    processes.compilerVersion = 'Swift version 6.4';
    final second = await ensure();
    expect(second.executable, isNot(first.executable));
    expect(processes.builds, 2);
    server = OpenAppleMacrosServer(
      runner: server.runner,
      layout: server.layout,
      sources: {...openAppleMacrosSources, 'Package.swift': '// changed'},
    );
    final third = await ensure();
    expect(third.executable, isNot(second.executable));
    expect(processes.builds, 3);
  });

  test('rebuilds a tampered server and leaves no staging behind', () async {
    final first = await ensure();
    File(first.executable).writeAsStringSync('tampered');
    final second = await ensure();
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
    await expectLater(ensure(), throwsA(isA<CliError>()));
    expect(
      Directory(p.join(root.path, 'open-apple-macros'))
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => p.basename(file.path)),
      isNot(
        anyOf(contains('identity.json'), contains('OpenAppleMacrosServer')),
      ),
    );
  });

  test('Dart module list matches the Swift server modules', () {
    final modules = RegExp(r'^\s*(\w+)\.all,\s*$', multiLine: true)
        .allMatches(
          openAppleMacrosSources['Sources/OpenAppleMacrosServer/Modules.swift']!,
        )
        .map((match) => match.group(1))
        .toList();
    expect(modules, openAppleMacroModules);
    final imports = RegExp(r'^import (\w+Macros)$', multiLine: true)
        .allMatches(sourceOpenAppleMacrosServerModulesSwift)
        .map((match) => match.group(1))
        .toList();
    expect(imports, openAppleMacroModules);
  });

  test('embedded sources match the tracked Swift package', () {
    final tracked = Directory(p.join('swift'));
    final files = {
      for (final file in tracked.listSync(recursive: true).whereType<File>())
        p.posix.joinAll(p.split(p.relative(file.path, from: tracked.path))):
            file.readAsStringSync().replaceAll('\r\n', '\n').trimRight(),
    }..removeWhere((path, _) => path.startsWith('.build/'));
    expect(files.keys.toSet(), openAppleMacrosSources.keys.toSet());
    for (final entry in openAppleMacrosSources.entries) {
      expect(
        entry.value.replaceAll('\r\n', '\n').trimRight(),
        files[entry.key],
        reason: entry.key,
      );
    }
  });
}
