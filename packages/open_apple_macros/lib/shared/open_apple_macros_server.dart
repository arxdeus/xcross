import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/errors/errors.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:open_apple_macros/host/shared/toolchain_plugin_layout.dart';
import 'package:open_apple_macros/src/shared/open_apple_macros_sources.dart';

@internal
const List<String> openAppleMacroModules = [
  'FoundationModelsMacros',
  'PreviewsMacros',
  'SwiftUIMacros',
];

final class SwiftToolCommand {
  const SwiftToolCommand(this.executable, [this.prefix = const []]);
  final String executable;
  final List<String> prefix;

  Map<String, Object> toJson() => {'executable': executable, 'prefix': prefix};
}

final class OpenAppleMacrosBuild {
  const OpenAppleMacrosBuild({
    required this.executable,
    required this.toolchainPluginDirectory,
    this.modules = openAppleMacroModules,
  });
  final String executable;
  final String toolchainPluginDirectory;
  final List<String> modules;

  List<String> get swiftcArguments => [
    '-plugin-path',
    toolchainPluginDirectory,
    '-load-plugin-executable',
    '$executable#${modules.join(',')}',
  ];

  List<String> get swiftBuildArguments => [
    for (final argument in swiftcArguments) ...['-Xswiftc', argument],
  ];
}

final class OpenAppleMacrosServer<T extends PlatformHostInterface> {
  OpenAppleMacrosServer({
    required this.runner,
    required this.layout,
    this.sources = openAppleMacrosSources,
  });
  final ProcessRunner<T> runner;
  final ToolchainPluginLayoutInterface layout;
  final Map<String, String> sources;

  static const String product = 'OpenAppleMacrosServer';

  T get host => runner.host;

  Future<OpenAppleMacrosBuild> ensure({
    required String cacheRoot,
    required SwiftToolCommand swiftDriver,
    required SwiftToolCommand swiftBuild,
    Map<String, String>? environment,
  }) async {
    final paths = host.paths.context;
    final targetInfo = await _targetInfo(swiftDriver, environment);
    final resourcePath = targetInfo.resourcePath;
    final identity = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'sources': sources,
              'toolchain': targetInfo.compilerVersion,
              'resources': resourcePath,
              'driver': swiftDriver.toJson(),
              'build': swiftBuild.toJson(),
              'host': host.name,
              'architecture': host.architecture,
            }),
          ),
        )
        .toString();
    final root = paths.join(
      cacheRoot,
      'open-apple-macros',
      identity.substring(0, 16),
    );
    final build = OpenAppleMacrosBuild(
      executable: paths.join(root, host.paths.executableName(product)),
      toolchainPluginDirectory: layout.pluginDirectory(paths, resourcePath),
    );
    final executable = host.fileSystem.file(build.executable);
    final stamp = host.fileSystem.file(paths.join(root, 'identity.json'));
    if (await _matches(executable, stamp, identity)) return build;

    final packageRoot = paths.join(root, 'src');
    for (final source in sources.entries) {
      final file = host.fileSystem.file(
        paths.joinAll([packageRoot, ...source.key.split('/')]),
      );
      if (file.existsSync() && await file.readAsString() == source.value) {
        continue;
      }
      await file.parent.create(recursive: true);
      await file.writeAsString(source.value);
    }
    final arguments = [
      ...swiftBuild.prefix,
      '--package-path',
      packageRoot,
      '--build-system',
      'native',
      '--configuration',
      'debug',
      '--scratch-path',
      paths.join(root, 'build'),
    ];
    await runner.runTool(
      swiftBuild.executable,
      [...arguments, '--product', product],
      environment: environment,
      label: 'build open apple macros server',
    );
    final binPath = await runner.run(swiftBuild.executable, [
      ...arguments,
      '--show-bin-path',
    ], environment: environment);
    final lines = const LineSplitter()
        .convert(binPath.stdout)
        .where((line) => line.trim().isNotEmpty);
    if (binPath.exitCode != 0 || lines.isEmpty) {
      throw CliError(
        'Could not locate the built $product: ${binPath.stderr.trim()}',
      );
    }
    final built = host.fileSystem.file(
      paths.join(lines.last.trim(), host.paths.executableName(product)),
    );
    if (!built.existsSync() || await built.length() == 0) {
      throw CliError('Swift build did not produce ${built.path}');
    }
    await _publish(built, executable, stamp, identity);
    return build;
  }

  Future<({String compilerVersion, String resourcePath})> _targetInfo(
    SwiftToolCommand swiftDriver,
    Map<String, String>? environment,
  ) async {
    final result = await runner.run(swiftDriver.executable, [
      ...swiftDriver.prefix,
      '-print-target-info',
    ], environment: environment);
    final decoded = result.exitCode == 0 ? _decode(result.stdout) : null;
    if (decoded case {
      'compilerVersion': final Object? version,
      'paths': {'runtimeResourcePath': final String resourcePath},
    }) {
      return (compilerVersion: '${version ?? ''}', resourcePath: resourcePath);
    }
    throw CliError(
      'Could not read the Swift toolchain layout from '
      '`${swiftDriver.executable} -print-target-info`: '
      '${result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr.trim()}',
    );
  }

  Object? _decode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  Future<bool> _matches(File executable, File stamp, String identity) async {
    if (!executable.existsSync() || !stamp.existsSync()) return false;
    final recorded = _decode(await stamp.readAsString());
    return recorded is Map &&
        recorded['identity'] == identity &&
        recorded['digest'] == await _digest(executable);
  }

  Future<String> _digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<void> _publish(
    File built,
    File executable,
    File stamp,
    String identity,
  ) async {
    final staging = await executable.parent.createTemp('publish-');
    try {
      final staged = await built.copy(
        host.paths.context.join(
          staging.path,
          host.paths.context.basename(executable.path),
        ),
      );
      runner.makeExecutable(staged.path);
      final digest = await _digest(staged);
      final stampDraft = host.fileSystem.file(
        host.paths.context.join(staging.path, 'identity.json'),
      );
      await stampDraft.writeAsString(
        jsonEncode({'identity': identity, 'digest': digest}),
      );
      await staged.rename(executable.path);
      await stampDraft.rename(stamp.path);
    } finally {
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }
}
