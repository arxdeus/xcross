import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';

/// Apple-only macro modules implemented by the OpenAppleMacros server.
///
/// `SwiftDataMacros` is deliberately absent: upstream ships it without any
/// macros, and registering it would shadow nothing useful.
@internal
const List<String> openAppleMacroModules = [
  'FoundationModelsMacros',
  'PreviewsMacros',
  'SwiftUIMacros',
];

/// Repository the release CI and the source fallback build the server from.
@internal
const String openAppleMacrosRepository =
    'https://github.com/arxdeus/OpenAppleMacros';

/// Revision of [openAppleMacrosRepository] this xcross was built against.
///
/// Keep in sync with the `third_party/OpenAppleMacros` submodule; a test pins
/// the two together.
@internal
const String openAppleMacrosRevision =
    'f94be34b395c6685bb0391ffa84d61a52240989a';

/// Product name of the compiler plugin server executable.
@internal
const String openAppleMacrosProduct = 'OpenAppleMacrosServer';

/// Where the Swift toolchain keeps its own (open-source) macro plugins.
@internal
abstract interface class ToolchainPluginLayoutInterface {
  String pluginDirectory(p.Context paths, String runtimeResourcePath);
}

/// `swift -print-target-info` command, optionally behind a launcher prefix.
@internal
final class SwiftToolCommand {
  const SwiftToolCommand(this.executable, [this.prefix = const []]);
  final String executable;
  final List<String> prefix;

  Map<String, Object> toJson() => {'executable': executable, 'prefix': prefix};
}

/// A ready server plus the toolchain plugin directory it must follow.
@internal
final class OpenAppleMacrosBuild {
  const OpenAppleMacrosBuild({
    required this.executable,
    required this.toolchainPluginDirectory,
    this.modules = openAppleMacroModules,
  });
  final String executable;
  final String toolchainPluginDirectory;
  final List<String> modules;

  /// Toolchain plugins come first so the open-source `SwiftMacros`,
  /// `ObservationMacros` and `FoundationMacros` win over any Apple plugins a
  /// Swift SDK might ship; the server then answers only the Apple modules.
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

/// Finds the OpenAppleMacros compiler plugin server.
///
/// Release bundles ship a prebuilt server in `lib/` next to xcross's native
/// libraries, built by the release workflow from the pinned
/// [openAppleMacrosRevision]. The compiler talks to it over the versioned
/// plugin message protocol, so one build serves every host Swift toolchain.
///
/// Builds without a bundled server (`dart run`, `dart pub global activate`)
/// fall back to fetching the pinned revision and building it once with the
/// host toolchain, then reuse the cached result.
@internal
final class OpenAppleMacrosServer<T extends PlatformHostInterface> {
  OpenAppleMacrosServer({
    required this.runner,
    required this.layout,
    required this.executable,
    this.launcher,
    this.configured,
  });

  final ProcessRunner<T> runner;
  final ToolchainPluginLayoutInterface layout;

  /// The running xcross (or the Dart VM for a source checkout).
  final String executable;

  /// A configured xcross launcher, whose `lib/` is checked first.
  final String? launcher;

  /// An explicit server path from `tools.OpenAppleMacrosServer`.
  final String? configured;

  T get host => runner.host;
  p.Context get _paths => host.paths.context;
  String get _name => host.paths.executableName(openAppleMacrosProduct);

  Future<OpenAppleMacrosBuild> ensure({
    required String cacheRoot,
    required SwiftToolCommand swiftDriver,
    required SwiftToolCommand swiftBuild,
    Map<String, String>? environment,
  }) async {
    final targetInfo = await _targetInfo(swiftDriver, environment);
    final pluginDirectory = layout.pluginDirectory(
      _paths,
      targetInfo.resourcePath,
    );
    final server =
        bundledServer() ??
        await _buildFromSource(
          cacheRoot: cacheRoot,
          targetInfo: targetInfo,
          swiftBuild: swiftBuild,
          environment: environment,
        );
    return OpenAppleMacrosBuild(
      executable: server,
      toolchainPluginDirectory: pluginDirectory,
    );
  }

  /// The configured or bundled server, if one exists.
  @visibleForTesting
  String? bundledServer() {
    if (configured case final path? when path.isNotEmpty) {
      if (!host.fileSystem.file(path).existsSync()) {
        throw FlutterBuildError(
          'Configured $openAppleMacrosProduct does not exist: $path',
        );
      }
      return path;
    }
    for (final binary in [?launcher, executable]) {
      // `<prefix>/bin/xcross` loads its native libraries from `<prefix>/lib`;
      // the server ships alongside them.
      final candidate = _paths.join(
        _paths.dirname(_paths.dirname(binary)),
        'lib',
        _name,
      );
      if (host.fileSystem.file(candidate).existsSync()) return candidate;
    }
    return null;
  }

  Future<String> _buildFromSource({
    required String cacheRoot,
    required _TargetInfo targetInfo,
    required SwiftToolCommand swiftBuild,
    Map<String, String>? environment,
  }) async {
    final identity = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'revision': openAppleMacrosRevision,
              'toolchain': targetInfo.compilerVersion,
              'build': swiftBuild.toJson(),
              'host': host.name,
              'architecture': host.architecture,
            }),
          ),
        )
        .toString();
    final root = _paths.join(
      cacheRoot,
      'open-apple-macros',
      identity.substring(0, 16),
    );
    final published = host.fileSystem.file(_paths.join(root, _name));
    final stamp = host.fileSystem.file(_paths.join(root, 'identity.json'));
    if (await _matches(published, stamp, identity)) return published.path;

    runner.log.logInfo(
      'Building $openAppleMacrosProduct from source (one time); release '
      'bundles ship it prebuilt.',
    );
    final source = await _sourceCheckout(root, environment);
    final arguments = [
      ...swiftBuild.prefix,
      '--package-path',
      source,
      '--configuration',
      'release',
      '--scratch-path',
      _paths.join(root, 'build'),
    ];
    await runner.runTool(
      swiftBuild.executable,
      [...arguments, '--product', openAppleMacrosProduct],
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
      throw FlutterBuildError(
        'Could not locate the built $openAppleMacrosProduct: '
        '${binPath.stderr.trim()}',
      );
    }
    final built = host.fileSystem.file(_paths.join(lines.last.trim(), _name));
    if (!built.existsSync() || await built.length() == 0) {
      throw FlutterBuildError('Swift build did not produce ${built.path}');
    }
    await _publish(built, published, stamp, identity);
    return published.path;
  }

  /// A shallow checkout of [openAppleMacrosRevision] under [root].
  Future<String> _sourceCheckout(
    String root,
    Map<String, String>? environment,
  ) async {
    final checkout = _paths.join(root, 'src');
    final manifest = host.fileSystem.file(
      _paths.join(checkout, 'Package.swift'),
    );
    if (manifest.existsSync() &&
        await _headRevision(checkout, environment) == openAppleMacrosRevision) {
      return checkout;
    }
    final directory = host.fileSystem.directory(checkout);
    if (directory.existsSync()) await directory.delete(recursive: true);
    await directory.create(recursive: true);
    final git = await runner.locateTool('git');
    for (final command in [
      ['init', '--quiet'],
      ['remote', 'add', 'origin', openAppleMacrosRepository],
      ['fetch', '--quiet', '--depth', '1', 'origin', openAppleMacrosRevision],
      ['checkout', '--quiet', '--detach', 'FETCH_HEAD'],
    ]) {
      await runner.runTool(
        git,
        command,
        workingDirectory: checkout,
        environment: environment,
        label: 'fetch open apple macros sources',
      );
    }
    return checkout;
  }

  Future<String?> _headRevision(
    String checkout,
    Map<String, String>? environment,
  ) async {
    final result = await runner.run(
      await runner.locateTool('git'),
      ['rev-parse', 'HEAD'],
      workingDirectory: checkout,
      environment: environment,
    );
    return result.exitCode == 0 ? result.stdout.trim() : null;
  }

  Future<_TargetInfo> _targetInfo(
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
    throw FlutterBuildError(
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
    await executable.parent.create(recursive: true);
    final staging = await executable.parent.createTemp('publish-');
    try {
      final staged = await built.copy(
        _paths.join(staging.path, _paths.basename(executable.path)),
      );
      runner.makeExecutable(staged.path);
      final digest = await _digest(staged);
      final stampDraft = host.fileSystem.file(
        _paths.join(staging.path, 'identity.json'),
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

typedef _TargetInfo = ({String compilerVersion, String resourcePath});
