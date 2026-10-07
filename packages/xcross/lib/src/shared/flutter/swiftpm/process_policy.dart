import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_compiler.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmProcessPolicy<T extends PlatformHostInterface> {
  SwiftPmProcessPolicy({
    required this.host,
    required this.hostPolicy,
    required this.runner,
    required this.tools,
  });
  final T host;
  final SwiftPmHostPolicy hostPolicy;
  final ProcessRunner<T> runner;
  final AppleToolShimResolver<T> tools;

  /// Environment that makes Git — and anything spawning it, including
  /// SwiftPM's own dependency resolution — fail instead of waiting on a
  /// human.
  ///
  /// Nothing is attached to this build's stdin: our runners pipe it and
  /// SwiftPM pipes its children too. So when a dependency's
  /// repository has moved, gone private, or started rate-limiting, Git's
  /// default answer — prompt for credentials — is a prompt no one can see
  /// or answer, and the child waits forever. On Windows, Git Credential
  /// Manager escalates that to an invisible GUI dialog. That is how a CI
  /// job sits for hours inside `Building Flutter plugins` printing nothing.
  ///
  /// * `GIT_TERMINAL_PROMPT=0` refuses username/password prompts on a tty.
  /// * Empty `GIT_ASKPASS`/`SSH_ASKPASS` with `SSH_ASKPASS_REQUIRE=never`
  ///   disables the graphical fallbacks Git uses when there is no tty.
  /// * `GCM_INTERACTIVE=never` and `GCM_PROVIDER=none` keep Git Credential
  ///   Manager from opening a window of its own.
  /// * `GIT_SSH_COMMAND` with `BatchMode=yes` fails an SSH remote outright
  ///   instead of asking for a passphrase or host-key confirmation.
  ///
  /// Each one turns a silent hang into an ordinary clone failure whose
  /// message names the repository that could not be read.
  static const Map<String, String> nonInteractiveGitEnvironment = {
    'GIT_TERMINAL_PROMPT': '0',
    'GIT_ASKPASS': '',
    'SSH_ASKPASS': '',
    'SSH_ASKPASS_REQUIRE': 'never',
    'GCM_INTERACTIVE': 'never',
    'GCM_PROVIDER': 'none',
    'GIT_SSH_COMMAND':
        'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new',
  };

  /// Git settings applied through `GIT_CONFIG_*`, in order.
  ///
  /// Resetting `credential.helper` closes the last door: a helper
  /// configured system-wide — Git Credential Manager on the Windows
  /// runners, `osxkeychain` on a developer's Mac — is consulted before any
  /// prompt setting applies, and it can block on its own UI. Clearing the
  /// list leaves Git with nobody to ask.
  ///
  /// The value is `""`, not the empty string: Git parses `GIT_CONFIG_VALUE_*`
  /// the way it parses a config file, and rejects a genuinely empty one with
  /// "missing config value ... fatal: unable to parse command-line config",
  /// which would fail every git command this build runs rather than only the
  /// ones that need credentials. Two quotes are the config-file spelling of
  /// an empty value, and an empty `credential.helper` is what resets the
  /// list.
  ///
  /// `core.symlinks=false` keeps Windows checkouts on placeholder files
  /// that [materializeGitCheckoutSymlinks] converts afterwards.
  List<({String key, String value})> gitConfigEntries() => [
    (key: 'credential.helper', value: '""'),
    (key: 'credential.interactive', value: 'false'),
    (key: 'http.lowSpeedLimit', value: '1024'),
    (key: 'http.lowSpeedTime', value: '60'),
    for (var index = 0; index < hostPolicy.gitConfiguration.length; index += 2)
      (
        key: hostPolicy.gitConfiguration[index],
        value: hostPolicy.gitConfiguration[index + 1],
      ),
  ];
  bool get sourceFallbackActive =>
      host.environment.lookup(
        host.environment.overlay(
          runner.effectiveEnvironment,
          _processEnvironment(),
        ),
        'EXPERIMENTAL_SPM_BUILDS',
      ) !=
      null;
  Future<Map<String, String>> swiftProcessEnvironment({
    String? executable,
    Map<String, String>? environment,
    Map<String, Set<String>> consumedProducts = const {},
  }) async => {
    ...await hostPolicy.hostEnvironment(),
    ..._processEnvironment(executable: executable, environment: environment),
    ...await manifestCompilerEnvironment(consumedProducts: consumedProducts),
  };
  Future<({String forwarder, SwiftPmManifestCompilerConfiguration base})?>?
  _manifestCompiler;
  final Map<String, Future<Map<String, String>>> _manifestCompilerShims = {};
  Future<Map<String, String>> manifestCompilerEnvironment({
    Map<String, Set<String>> consumedProducts = const {},
  }) async {
    final installation = await (_manifestCompiler ??=
        _resolveManifestCompiler());
    if (installation == null) return const {};
    final products = {
      for (final identity in consumedProducts.keys.toList()..sort())
        if (consumedProducts[identity]!.isNotEmpty)
          identity: consumedProducts[identity]!.toList()..sort(),
    };
    final base = installation.base;
    final digest = manifestCompilerEnvironmentDigest(base.policy, products);
    return _manifestCompilerShims[digest] ??= _installManifestCompiler(
      forwarder: installation.forwarder,
      digest: digest,
      configuration: SwiftPmManifestCompilerConfiguration(
        compiler: base.compiler,
        cacheRoot: base.cacheRoot,
        policy: base.policy,
        consumedProducts: products,
      ),
    );
  }

  Future<Map<String, String>> _installManifestCompiler({
    required String forwarder,
    required String digest,
    required SwiftPmManifestCompilerConfiguration configuration,
  }) async {
    try {
      final shim = await hostPolicy.installManifestCompiler(
        host,
        directory: host.paths.context.join(
          configuration.cacheRoot,
          'manifest-compiler',
          'bin-${digest.substring(0, 16)}',
        ),
        executable: forwarder,
        configuration: jsonEncode(configuration.toJson()),
      );
      return {'SWIFT_EXEC_MANIFEST': shim, manifestPolicyVariable: digest};
    } on FileSystemException catch (error) {
      runner.log.logTrace('manifest compiler unavailable: $error');
      return const {};
    }
  }

  Future<({String forwarder, SwiftPmManifestCompilerConfiguration base})?>
  _resolveManifestCompiler() async {
    final paths = host.paths.context;
    final String forwarder;
    final String swift;
    try {
      forwarder = await tools.resolveNativeAssetToolForwarder(tools.executable);
      swift = await runner.locateTool(hostPolicy.packageTool);
    } on Object {
      return null;
    }
    final forwarderFile = host.fileSystem.file(host.paths.ioPath(forwarder));
    if (paths.basenameWithoutExtension(forwarder).toLowerCase() != 'xcross' ||
        !forwarderFile.existsSync()) {
      return null;
    }
    final inherited = host.environment.lookup(
      runner.effectiveEnvironment,
      'SWIFT_EXEC_MANIFEST',
    );
    final compiler =
        inherited != null &&
            inherited.isNotEmpty &&
            paths.basenameWithoutExtension(inherited) != manifestCompilerName
        ? inherited
        : paths.join(paths.dirname(swift), runner.hostExecutableName('swiftc'));
    if (!host.fileSystem.file(host.paths.ioPath(compiler)).existsSync()) {
      return null;
    }
    final configured = host.environment.lookup(
      runner.effectiveEnvironment,
      'XCROSS_CACHE_DIR',
    );
    final cacheRoot = configured != null && configured.isNotEmpty
        ? configured
        : paths.join(host.paths.cacheRoot, 'xcross');
    final stat = forwarderFile.statSync();
    final policy = manifestCompilerPolicyDigest({
      'host': host.name,
      'executable': [
        forwarder,
        stat.size,
        stat.modified.millisecondsSinceEpoch,
      ],
      'compiler': compiler,
      'manifestArguments': hostPolicy.manifestArguments,
    });
    return (
      forwarder: forwarder,
      base: SwiftPmManifestCompilerConfiguration(
        compiler: compiler,
        cacheRoot: cacheRoot,
        policy: policy,
      ),
    );
  }

  Map<String, String> _processEnvironment({
    String? executable,
    Map<String, String>? environment,
  }) {
    final config = gitConfigEntries();
    return {
      ...nonInteractiveGitEnvironment,
      'GIT_CONFIG_COUNT': '${config.length}',
      for (final (index, entry) in config.indexed) ...{
        'GIT_CONFIG_KEY_$index': entry.key,
        'GIT_CONFIG_VALUE_$index': entry.value,
      },
      ...hostPolicy.sourceEnvironment,
      ...hostPolicy.bundledToolEnvironment(
        executable ?? tools.executable,
        environment ?? runner.effectiveEnvironment,
      ),
    };
  }

  /// Resolves Windows dependencies before tracked symlink placeholders are
  /// materialized and automatic resolution is disabled for the build.
  List<String> swiftResolveArguments({
    required String pluginsDir,
    required String scratchPath,
    required String swiftSdksPath,
    required String toolsetPath,
    String swiftSdkTriple = 'arm64-apple-ios',
  }) => [
    ...hostPolicy.packagePrefix,
    ...hostManifestArguments(),
    '--package-path',
    pluginsDir,
    '--scratch-path',
    scratchPath,
    '--swift-sdks-path',
    swiftSdksPath,
    '--swift-sdk',
    swiftSdkTriple,
    '--toolset',
    toolsetPath,
    'resolve',
  ];

  /// Supply the Windows C runtime to host manifests, including remote manifests
  /// SwiftPM evaluates before creating a checkout. Swift 6 replaced MSVCRT with
  /// CRT, so old conditional imports otherwise leave C APIs such as getenv
  /// unavailable. These flags affect host manifests, never iOS target sources.
  List<String> hostManifestArguments() => hostPolicy.manifestArguments;
}
