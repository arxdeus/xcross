import 'dart:io';

import 'package:cli_kit/src/shared/errors/errors.dart';
import 'package:cli_kit/src/shared/platform/platform_host.dart';
import 'package:cli_kit/src/shared/process/process_models.dart';

abstract interface class ProcessToolLookupInterface<
  T extends PlatformHostInterface
> {
  T get host;
  ProcessConfiguration? get configuration;
  Map<String, String> get effectiveEnvironment;
  String resolveExecutable(String executable);
  String hostExecutableName(String name, {String extension = '.exe'});
  String? environmentValue(Map<String, String> environment, String name);
  bool isSwiftlyProxy(String path);
  Future<String?> which(
    String name, {
    Map<String, String>? environment,
    bool Function(String)? accept,
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  });
  Future<List<String>> whichAll(
    String name, {
    Map<String, String>? environment,
    bool Function(String)? accept,
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  });
  Future<String> locateTool(
    String name, {
    Iterable<String> extraDirectories = const [],
  });
}

final class ProcessToolLookup<T extends PlatformHostInterface>
    implements ProcessToolLookupInterface<T> {
  ProcessToolLookup(this.host, {this.configuration});
  @override
  final T host;
  @override
  final ProcessConfiguration? configuration;
  @override
  Map<String, String> get effectiveEnvironment =>
      configuration?.effectiveChildEnvironment ?? host.environment.values;
  @override
  String resolveExecutable(String executable) {
    final configured = configuration;
    if (configured == null || host.paths.context.isAbsolute(executable)) {
      return executable;
    }
    final override =
        configured.normalizedTools[_normalizedToolName(executable)];
    return override ?? _toolchainOverride(executable, configured) ?? executable;
  }

  @override
  String hostExecutableName(String name, {String extension = '.exe'}) =>
      host.paths.executableName(name, extension: extension);

  @override
  bool isSwiftlyProxy(String path) {
    try {
      final target = host.fileSystem.file(path).resolveSymbolicLinksSync();
      return host.paths.context.basenameWithoutExtension(target) == 'swiftly';
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<String?> which(
    String name, {
    Map<String, String>? environment,
    bool Function(String path)? accept,
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  }) async => (await whichAll(
    name,
    environment: environment,
    accept: accept,
    extraDirectories: extraDirectories,
    useConfiguration: useConfiguration,
  )).firstOrNull;

  @override
  Future<List<String>> whichAll(
    String name, {
    Map<String, String>? environment,
    bool Function(String path)? accept,
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  }) async {
    final configured = useConfiguration ? configuration : null;
    final env = configured == null
        ? environment ?? effectiveEnvironment
        : host.environment.overlay(
            effectiveEnvironment,
            environment ?? const {},
          );
    final names = host.environment.executableCandidates(name, env);
    final override = _configuredToolOverride(
      configured?.normalizedTools,
      names,
    );
    if (override != null && (accept == null || accept(override))) {
      return [override];
    }
    final toolchain = configured == null
        ? null
        : _toolchainOverride(name, configured, accept: accept);

    final found = <String>[if (toolchain != null) toolchain];
    final seen = <String>{};
    final searchPath = environmentValue(env, 'PATH') ?? '';
    final directories = [
      ...host.environment.splitPathList(searchPath),
      ...extraDirectories,
    ];
    if (toolchain != null) {
      seen.add(host.paths.pathKey(toolchain));
    }
    for (final dir in directories) {
      if (dir.isEmpty) continue;
      for (final candidateName in names) {
        final candidate = host.paths.context.join(dir, candidateName);
        final absoluteCandidate = host.paths.context.normalize(
          host.paths.context.absolute(candidate),
        );
        final candidateKey = host.paths.pathKey(absoluteCandidate);
        if (!seen.add(candidateKey)) {
          continue;
        }

        if (host.fileSystem.file(candidate).existsSync() &&
            (accept == null || accept(candidate))) {
          found.add(candidate);
        }
      }
    }
    return found;
  }

  static const _swiftExecutables = {
    'swift',
    'swiftc',
    'swift-package',
    'swift-build',
    'swift-frontend',
  };
  static const _llvmExecutables = {'clang', 'clang++', 'ld64.lld', 'dsymutil'};
  static const _windowsExecutableExtensions = ['.exe', '.cmd', '.bat', '.com'];

  String? _toolchainOverride(
    String name,
    ProcessConfiguration configuration, {
    bool Function(String path)? accept,
  }) {
    final executable = _toolchainExecutable(name);
    if (executable == null) return null;

    final directories =
        configuration.toolchainDirectories[executable.toolchain];
    if (directories == null) return null;

    final candidates = host.environment.executableCandidates(
      executable.basename,
      configuration.effectiveChildEnvironment,
    );
    return _firstAcceptedTool(directories, candidates, accept);
  }

  ({String toolchain, String basename})? _toolchainExecutable(String name) {
    final normalized = _normalizedToolName(name);
    if (_swiftExecutables.contains(normalized)) {
      return (toolchain: 'swift', basename: normalized);
    }
    if (normalized == 'cc') {
      return (toolchain: 'llvm', basename: 'clang');
    }
    if (_llvmExecutables.contains(normalized) ||
        normalized.startsWith('llvm-')) {
      return (toolchain: 'llvm', basename: normalized);
    }
    return null;
  }

  String? _firstAcceptedTool(
    Iterable<String> directories,
    Iterable<String> candidates,
    bool Function(String path)? accept,
  ) {
    for (final directory in directories) {
      for (final candidate in candidates) {
        final path = host.paths.context.join(directory, candidate);
        if (host.fileSystem.file(path).existsSync() &&
            (accept == null || accept(path))) {
          return path;
        }
      }
    }
    return null;
  }

  String? _configuredToolOverride(
    Map<String, String>? tools,
    Iterable<String> candidateNames,
  ) {
    if (tools == null) return null;
    for (final candidate in candidateNames) {
      final override = tools[_normalizedToolName(candidate)];
      if (override != null) return override;
    }
    return null;
  }

  String _normalizedToolName(String name) {
    final normalized = name.trim().toLowerCase();
    for (final extension in _windowsExecutableExtensions) {
      if (normalized.endsWith(extension)) {
        return normalized.substring(0, normalized.length - extension.length);
      }
    }
    return normalized;
  }

  @override
  String? environmentValue(Map<String, String> env, String name) =>
      host.environment.lookup(env, name);

  @override
  Future<String> locateTool(
    String name, {
    Iterable<String> extraDirectories = const [],
  }) async {
    final found = await which(name, extraDirectories: extraDirectories);
    if (found != null) return found;
    final fallback = await host.processes.findOnShellPath(
      name,
      environment: effectiveEnvironment,
      includeParentEnvironment: false,
    );
    if (fallback != null) return fallback;
    throw CliError("Could not find '$name' in PATH.");
  }
}
