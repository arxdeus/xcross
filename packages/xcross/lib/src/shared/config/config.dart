import 'dart:convert';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/config/config_decoder.dart';
import 'package:xcross/src/shared/config/config_host.dart';
import 'package:yaml/yaml.dart';

const _notProvided = ConfigNotProvided();

@internal
final class ConfigNotProvided {
  const ConfigNotProvided();
}

/// A malformed or incomplete xcross configuration.
@internal
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
@internal
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
@internal
final class XcrossConfigToolchains {
  const XcrossConfigToolchains({this.swift, this.llvm = const []});

  final String? swift;
  final List<String> llvm;

  bool get isEmpty => swift == null && llvm.isEmpty;
}

/// Contents of an xcross YAML configuration.
@internal
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
       tools = Map.unmodifiable(_validateTools(tools)),
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

  String? tool(String name) => tools[name];

  static Uri? remoteSetupScriptUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.scheme == 'https' || uri.scheme == 'http' ? uri : null;
  }

  static String _normalizeCommandName(String name) => name.trim().toLowerCase();

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

  static Map<String, String> _validateTools(Map<String, String> source) {
    final result = <String, String>{};
    for (final entry in source.entries) {
      rejectUnsafeConfigString(entry.key, 'Tool name');
      if (entry.key.trim().isEmpty) {
        throw const XcrossConfigException('Tool names must not be empty');
      }
      rejectUnsafeConfigString(entry.value, 'Tool path for ${entry.key}');
      if (entry.value.trim().isEmpty) {
        throw XcrossConfigException(
          'Tool path for ${entry.key} must not be empty',
        );
      }
      result[entry.key] = entry.value;
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
