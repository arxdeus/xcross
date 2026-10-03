import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/config/config_decoder.dart';
import 'package:xcross/src/shared/config/config_host.dart';
import 'package:yaml/yaml.dart';

export 'package:xcross/src/config/config_decoder.dart'
    show expandNativeEnvironment;
export 'package:xcross/src/config/config_store.dart';

const _notProvided = ConfigNotProvided();
const _windowsExecutableExtensions = {'.exe', '.com', '.bat', '.cmd'};

final class ConfigNotProvided {
  const ConfigNotProvided();
}

/// A malformed or incomplete xcross configuration.
final class XcrossConfigException implements Exception {
  const XcrossConfigException(this.message, {this.path});

  final String message;
  final String? path;

  @override
  String toString() => path == null
      ? 'XcrossConfigException: $message'
      : 'XcrossConfigException at $path: $message';
}

/// Optional install roots understood by xcross commands.
final class XcrossConfigRoots {
  const XcrossConfigRoots({
    this.darwinSdk,
    this.flutterSdk,
    this.xcross,
    this.javaHome,
    this.konanData,
  });

  final String? darwinSdk;
  final String? flutterSdk;
  final String? xcross;
  final String? javaHome;
  final String? konanData;

  XcrossConfigRoots copyWith({
    Object? darwinSdk = _notProvided,
    Object? flutterSdk = _notProvided,
    Object? xcross = _notProvided,
    Object? javaHome = _notProvided,
    Object? konanData = _notProvided,
  }) => XcrossConfigRoots(
    darwinSdk: darwinSdk == _notProvided
        ? this.darwinSdk
        : darwinSdk as String?,
    flutterSdk: flutterSdk == _notProvided
        ? this.flutterSdk
        : flutterSdk as String?,
    xcross: xcross == _notProvided ? this.xcross : xcross as String?,
    javaHome: javaHome == _notProvided ? this.javaHome : javaHome as String?,
    konanData: konanData == _notProvided
        ? this.konanData
        : konanData as String?,
  );

  Map<String, String> toMap() => {
    if (darwinSdk != null) 'darwinSdk': darwinSdk!,
    if (flutterSdk != null) 'flutterSdk': flutterSdk!,
    if (xcross != null) 'xcross': xcross!,
    if (javaHome != null) 'javaHome': javaHome!,
    if (konanData != null) 'konanData': konanData!,
  };
}

/// Optional compiler toolchain binary directories.
final class XcrossConfigToolchains {
  const XcrossConfigToolchains({this.swift, this.llvm = const []});

  final String? swift;
  final List<String> llvm;

  bool get isEmpty => swift == null && llvm.isEmpty;
}

/// Contents of an xcross YAML configuration.
final class XcrossConfig {
  XcrossConfig({
    this.roots = const XcrossConfigRoots(),
    XcrossConfigToolchains toolchains = const XcrossConfigToolchains(),
    Map<String, String> tools = const {},
    Map<String, Object> environment = const {},
    this.setup,
    Iterable<String> excludedCommands = const [],
  }) : toolchains = XcrossConfigToolchains(
         swift: toolchains.swift,
         llvm: List.unmodifiable(toolchains.llvm),
       ),
       tools = Map.unmodifiable(_normalizeTools(tools)),
       environment = Map.unmodifiable(_normalizeEnvironment(environment)),
       excludedCommands = Set.unmodifiable(
         excludedCommands.map(_normalizeCommandName).toSet(),
       );

  /// Variables that configured child processes may inherit.
  ///
  /// This is deliberately separate from variables accepted as expansion
  /// sources (for example, HOME and USERPROFILE).
  static const environmentAllowlist = <String>{
    'PATH',
    'CC',
    'CXX',
    'SWIFT_EXEC',
    'SWIFT_EXEC_MANIFEST',
    'JAVA_HOME',
    'FLUTTER_ROOT',
    'KONAN_DATA_DIR',
    'LIBRARY_PATH',
    'C_INCLUDE_PATH',
    'CPLUS_INCLUDE_PATH',
  };

  final XcrossConfigRoots roots;
  final XcrossConfigToolchains toolchains;
  final Map<String, String> tools;

  /// Allowlisted environment values. `PATH` is a list; all others are strings.
  final Map<String, Object> environment;
  final String? setup;
  final Set<String> excludedCommands;

  XcrossConfig copyWith({
    XcrossConfigRoots? roots,
    XcrossConfigToolchains? toolchains,
    Map<String, String>? tools,
    Map<String, Object>? environment,
    Object? setup = _notProvided,
    Iterable<String>? excludedCommands,
  }) => XcrossConfig(
    roots: roots ?? this.roots,
    toolchains: toolchains ?? this.toolchains,
    tools: tools ?? this.tools,
    environment: environment ?? this.environment,
    setup: setup == _notProvided ? this.setup : setup as String?,
    excludedCommands: excludedCommands ?? this.excludedCommands,
  );

  String? tool(String name) => tools[normalizeToolName(name)];

  /// Validates paths needed by the configured operations.
  ///
  /// Roots must be absolute, but are not required to exist. Tool overrides must
  /// point to existing regular executable files.
  void validate({
    required PlatformHostInterface host,
    required ConfigHostInterface policy,
  }) {
    final configHost = policy;
    final pathContext = host.paths.context;

    _validateRoots(pathContext);
    _validateToolchains(pathContext);
    _validateTools(pathContext, configHost);
    if (setup case final value?) _validateSetupScript(value, pathContext);
    _validateExcludedCommands();
    _validateEnvironment(pathContext);
  }

  void _validateRoots(p.Context pathContext) {
    for (final entry in roots.toMap().entries) {
      rejectUnsafeConfigString(entry.value, 'Root ${entry.key}');
      if (!pathContext.isAbsolute(entry.value)) {
        throw XcrossConfigException(
          'Root ${entry.key} must be an absolute path: ${entry.value}',
        );
      }
    }
  }

  void _validateToolchains(p.Context pathContext) {
    final directories = <MapEntry<String, String>>[
      if (toolchains.swift case final swift?) MapEntry('swift', swift),
      for (final llvm in toolchains.llvm) MapEntry('llvm', llvm),
    ];
    for (final entry in directories) {
      rejectUnsafeConfigString(entry.value, 'Toolchain ${entry.key} directory');
      if (!pathContext.isAbsolute(entry.value)) {
        throw XcrossConfigException(
          'Toolchain ${entry.key} must use an absolute bin directory: ${entry.value}',
        );
      }
    }
  }

  void _validateTools(p.Context pathContext, ConfigHostInterface policy) {
    for (final entry in tools.entries) {
      rejectUnsafeConfigString(entry.key, 'Tool name');
      rejectUnsafeConfigString(entry.value, 'Tool ${entry.key} path');
      if (!pathContext.isAbsolute(entry.value)) {
        throw XcrossConfigException(
          'Tool ${entry.key} must use an absolute path: ${entry.value}',
        );
      }
      final stat = FileStat.statSync(entry.value);
      if (stat.type != FileSystemEntityType.file) {
        throw XcrossConfigException(
          'Tool ${entry.key} must be a regular file: ${entry.value}',
        );
      }
      final executable = policy.isExecutable(entry.value, stat);
      if (!executable) {
        throw XcrossConfigException(
          'Tool ${entry.key} is not executable: ${entry.value}',
        );
      }
    }
  }

  void _validateExcludedCommands() {
    for (final command in excludedCommands) {
      rejectUnsafeConfigString(command, 'Excluded command');
      if (command.isEmpty || command.contains(RegExp(r'\s'))) {
        throw XcrossConfigException(
          'Excluded commands must be non-empty top-level command names: $command',
        );
      }
    }
  }

  void _validateEnvironment(p.Context pathContext) {
    for (final entry in environment.entries) {
      if (entry.value case final List<String> paths) {
        for (final value in paths) {
          rejectUnsafeConfigString(value, 'Environment ${entry.key} entry');
          if (!pathContext.isAbsolute(value)) {
            throw XcrossConfigException(
              'Environment ${entry.key} entries must be absolute paths: $value',
            );
          }
        }
      } else {
        rejectUnsafeConfigString(
          entry.value as String,
          'Environment ${entry.key}',
        );
      }
    }
  }

  static Uri? remoteSetupScriptUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.scheme == 'https' || uri.scheme == 'http' ? uri : null;
  }

  static void _validateSetupScript(String value, p.Context pathContext) {
    rejectUnsafeConfigString(value, 'Setup script');
    if (remoteSetupScriptUri(value) == null && !pathContext.isAbsolute(value)) {
      throw XcrossConfigException(
        'Setup script must be an absolute local path or HTTP(S) URL: $value',
      );
    }
  }

  static String _normalizeCommandName(String name) => name.trim().toLowerCase();

  static String normalizeToolName(String name) {
    var normalized = name.trim().toLowerCase();
    for (final extension in _windowsExecutableExtensions) {
      if (normalized.endsWith(extension)) {
        normalized = normalized.substring(
          0,
          normalized.length - extension.length,
        );
        break;
      }
    }
    return normalized;
  }

  factory XcrossConfig.parse(
    String source, {
    required PlatformHostInterface host,
    required ConfigHostInterface policy,
    String? sourcePath,
    Map<String, String>? environment,
  }) {
    Object? document;
    try {
      document = loadYaml(source);
    } on YamlException catch (error) {
      throw XcrossConfigException(
        'Invalid YAML: ${error.message}',
        path: sourcePath,
      );
    }
    return XcrossConfigDecoder(
      document: document,
      sourcePath: sourcePath,
      environment: environment ?? host.environment.values,
      host: host,
      policy: policy,
    ).decode();
  }

  /// Alias suitable for callers that treat parsing as deserialization.
  factory XcrossConfig.fromYaml(
    String source, {
    required PlatformHostInterface host,
    required ConfigHostInterface policy,
    String? sourcePath,
    Map<String, String>? environment,
  }) => XcrossConfig.parse(
    source,
    sourcePath: sourcePath,
    environment: environment,
    host: host,
    policy: policy,
  );

  /// Stable YAML with fixed section order and sorted arbitrary maps.
  String toYaml() {
    final buffer = StringBuffer('roots:\n');
    for (final entry in roots.toMap().entries) {
      buffer.writeln('  ${entry.key}: ${_yamlString(entry.value)}');
    }
    buffer.writeln('toolchains:');
    if (toolchains.swift case final swift?) {
      buffer.writeln('  swift: ${_yamlString(swift)}');
    }
    if (toolchains.llvm.length == 1) {
      buffer.writeln('  llvm: ${_yamlString(toolchains.llvm.single)}');
    } else if (toolchains.llvm.isNotEmpty) {
      buffer.writeln('  llvm:');
      for (final directory in toolchains.llvm) {
        buffer.writeln('    - ${_yamlString(directory)}');
      }
    }
    buffer.writeln('tools:');
    for (final entry in _sorted(tools).entries) {
      buffer.writeln(
        '  ${_yamlString(entry.key)}: ${_yamlString(entry.value)}',
      );
    }
    if (setup case final value?) {
      buffer.writeln('setup: ${_yamlString(value)}');
    }
    buffer.writeln('excluded_commands:');
    for (final command in excludedCommands.toList()..sort()) {
      buffer.writeln('  - ${_yamlString(command)}');
    }
    buffer.writeln('environment:');
    for (final entry in _sortedObjects(environment).entries) {
      if (entry.value case final List<String> paths) {
        buffer.writeln('  ${entry.key}:');
        for (final path in paths) {
          buffer.writeln('    - ${_yamlString(path)}');
        }
      } else {
        buffer.writeln('  ${entry.key}: ${_yamlString(entry.value as String)}');
      }
    }
    return buffer.toString();
  }

  static Map<String, Object> _normalizeEnvironment(Map<String, Object> source) {
    final result = <String, Object>{};
    for (final entry in source.entries) {
      if (!environmentAllowlist.contains(entry.key)) {
        throw XcrossConfigException(
          'Environment variable ${entry.key} is not allowlisted',
        );
      }
      rejectUnsafeConfigString(entry.key, 'Environment variable name');
      if (entry.key == 'PATH') {
        if (entry.value is! List<String> ||
            (entry.value as List<String>).any(
              (value) => value.trim().isEmpty,
            )) {
          throw const XcrossConfigException(
            'Environment variable PATH must be a list of non-empty strings',
          );
        }
        final paths = entry.value as List<String>;
        for (final value in paths) {
          rejectUnsafeConfigString(value, 'Environment PATH entry');
        }
        result[entry.key] = List<String>.unmodifiable(paths);
      } else if (entry.value is String &&
          (entry.value as String).trim().isNotEmpty) {
        rejectUnsafeConfigString(
          entry.value as String,
          'Environment variable ${entry.key}',
        );
        result[entry.key] = entry.value;
      } else {
        throw XcrossConfigException(
          'Environment variable ${entry.key} must be a non-empty string',
        );
      }
    }
    return result;
  }

  static Map<String, String> _normalizeTools(Map<String, String> source) {
    final result = <String, String>{};
    for (final entry in source.entries) {
      final key = normalizeToolName(entry.key);
      rejectUnsafeConfigString(entry.key, 'Tool name');
      if (key.isEmpty || result.containsKey(key)) {
        throw XcrossConfigException(
          'Invalid or duplicate tool name: ${entry.key}',
        );
      }
      rejectUnsafeConfigString(entry.value, 'Tool path for ${entry.key}');
      if (entry.value.trim().isEmpty) {
        throw XcrossConfigException(
          'Tool path for ${entry.key} must not be empty',
        );
      }
      result[key] = entry.value;
    }
    return result;
  }
}

Map<String, String> _sorted(Map<String, String> values) {
  final keys = values.keys.toList()..sort();
  return {for (final key in keys) key: values[key]!};
}

Map<String, Object> _sortedObjects(Map<String, Object> values) {
  final keys = values.keys.toList()..sort();
  return {for (final key in keys) key: values[key]!};
}

String _yamlString(String value) => jsonEncode(value);
