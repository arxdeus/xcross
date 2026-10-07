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
  /// SwiftPM pipes its children too. So when a vendored dependency's
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
  /// that [materializeGitCheckoutSymlinks] converts afterwards. Our own
  /// clones override it per command with `-c core.symlinks=true` where the
  /// host can create real symlinks; a command-line `-c` outranks these.
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
  }) async => {
    ...await hostPolicy.hostEnvironment(),
    ..._processEnvironment(executable: executable, environment: environment),
    ...await manifestCompilerEnvironment(),
  };
  Future<Map<String, String>>? _manifestCompiler;
  Future<Map<String, String>> manifestCompilerEnvironment() =>
      _manifestCompiler ??= _installManifestCompiler();
  Future<Map<String, String>> _installManifestCompiler() async {
    final paths = host.paths.context;
    final String forwarder;
    final String swift;
    try {
      forwarder = await tools.resolveNativeAssetToolForwarder(tools.executable);
      swift = await runner.locateTool(hostPolicy.packageTool);
    } on Object {
      return const {};
    }
    final forwarderFile = host.fileSystem.file(host.paths.ioPath(forwarder));
    if (paths.basenameWithoutExtension(forwarder).toLowerCase() != 'xcross' ||
        !forwarderFile.existsSync()) {
      return const {};
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
      return const {};
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
    final configuration = jsonEncode(
      SwiftPmManifestCompilerConfiguration(
        compiler: compiler,
        cacheRoot: cacheRoot,
        policy: policy,
      ).toJson(),
    );
    try {
      final shim = await hostPolicy.installManifestCompiler(
        host,
        directory: paths.join(
          cacheRoot,
          'manifest-compiler',
          'bin-${policy.substring(0, 16)}',
        ),
        executable: forwarder,
        configuration: configuration,
      );
      return {'SWIFT_EXEC_MANIFEST': shim, manifestPolicyVariable: policy};
    } on FileSystemException catch (error) {
      runner.log.logTrace('manifest compiler unavailable: $error');
      return const {};
    }
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
