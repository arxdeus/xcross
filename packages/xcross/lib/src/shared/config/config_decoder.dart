import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/config/config.dart';
import 'package:xcross/src/shared/config/config_host.dart';

const _maximumEnvironmentExpansionDepth = 32;

final class XcrossConfigDecoder {
  const XcrossConfigDecoder({
    required this.document,
    required this.sourcePath,
    required this.environment,
    required this.host,
    required this.policy,
  });

  static const _rootKeys = {
    'roots',
    'toolchains',
    'tools',
    'environment',
    'excluded_commands',
    'setup',
  };
  static const _rootsKeys = {
    'darwinSdk',
    'flutterSdk',
    'xcross',
    'javaHome',
    'konanData',
  };
  static const _toolchainKeys = {'swift', 'llvm'};

  final Object? document;
  final String? sourcePath;
  final Map<String, String> environment;
  final PlatformHostInterface host;
  final ConfigHostInterface policy;

  XcrossConfig decode() {
    final root = _stringMap(document, r'$', sourcePath);
    _onlyKeys(root, _rootKeys, r'$', sourcePath);

    final config = XcrossConfig(
      roots: _decodeRoots(root['roots']),
      toolchains: _decodeToolchains(root['toolchains']),
      tools: _decodeTools(root['tools']),
      environment: _decodeEnvironment(root['environment']),
      setup: _optionalString(root['setup'], r'$.setup'),
      excludedCommands: _optionalStringList(
        root['excluded_commands'],
        r'$.excluded_commands',
      ),
    );
    XcrossConfigValidator(
      fileSystem: host.fileSystem,
      pathContext: host.paths.context,
      policy: policy,
    ).validate(config);
    return config;
  }

  XcrossConfigRoots _decodeRoots(Object? value) {
    final roots = _optionalMap(value, r'$.roots');
    _onlyKeys(roots, _rootsKeys, r'$.roots', sourcePath);

    return XcrossConfigRoots(
      darwinSdk: _optionalString(roots['darwinSdk'], r'$.roots.darwinSdk'),
      flutterSdk: _optionalString(roots['flutterSdk'], r'$.roots.flutterSdk'),
      xcross: _optionalString(roots['xcross'], r'$.roots.xcross'),
      javaHome: _optionalString(roots['javaHome'], r'$.roots.javaHome'),
      konanData: _optionalString(roots['konanData'], r'$.roots.konanData'),
    );
  }

  XcrossConfigToolchains _decodeToolchains(Object? value) {
    final toolchains = _optionalMap(value, r'$.toolchains');
    _onlyKeys(toolchains, _toolchainKeys, r'$.toolchains', sourcePath);

    final llvm = toolchains['llvm'];
    return XcrossConfigToolchains(
      swift: _optionalString(toolchains['swift'], r'$.toolchains.swift'),
      llvm: llvm == null
          ? const []
          : llvm is String
          ? [_requiredString(llvm, r'$.toolchains.llvm')]
          : _requiredStringList(llvm, r'$.toolchains.llvm'),
    );
  }

  Map<String, String> _decodeTools(Object? value) {
    final node = _optionalMap(value, r'$.tools');
    final tools = <String, String>{};
    for (final entry in node.entries) {
      final name = XcrossConfig.normalizeToolName(entry.key);
      if (name.isEmpty) {
        throw XcrossConfigException(
          'Tool names must not be empty',
          path: sourcePath,
        );
      }
      if (tools.containsKey(name)) {
        throw XcrossConfigException(
          'Duplicate tool after executable-extension normalization: ${entry.key}',
          path: sourcePath,
        );
      }
      tools[name] = _requiredString(entry.value, r'$.tools.' + entry.key);
    }
    return tools;
  }

  Map<String, Object> _decodeEnvironment(Object? value) {
    final node = _optionalMap(value, r'$.environment');
    final configured = <String, Object>{};
    for (final entry in node.entries) {
      if (!XcrossConfig.environmentAllowlist.contains(entry.key)) {
        throw XcrossConfigException(
          'Environment variable ${entry.key} is not allowlisted',
          path: sourcePath,
        );
      }
      configured[entry.key] = entry.key == 'PATH'
          ? _requiredStringList(entry.value, r'$.environment.PATH')
          : _requiredString(entry.value, r'$.environment.' + entry.key);
    }
    return configured;
  }

  Map<String, Object?> _optionalMap(Object? value, String field) =>
      value == null
      ? <String, Object?>{}
      : _stringMap(value, field, sourcePath);

  String? _optionalString(Object? value, String field) =>
      value == null ? null : _requiredString(value, field);

  String _requiredString(Object? value, String field) =>
      _expandedString(value, field, environment, host, policy, sourcePath);

  List<String> _optionalStringList(Object? value, String field) =>
      value == null ? const [] : _requiredStringList(value, field);

  List<String> _requiredStringList(Object? value, String field) =>
      _expandedStringList(value, field, environment, host, policy, sourcePath);
}

Map<String, Object?> _stringMap(
  Object? value,
  String field,
  String? sourcePath,
) {
  if (value is! Map) {
    throw XcrossConfigException('$field must be a mapping', path: sourcePath);
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw XcrossConfigException(
        '$field keys must be strings',
        path: sourcePath,
      );
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

void _onlyKeys(
  Map<String, Object?> map,
  Set<String> allowed,
  String field,
  String? sourcePath,
) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw XcrossConfigException('Unknown key $field.$key', path: sourcePath);
    }
  }
}

String _expandedString(
  Object? value,
  String field,
  Map<String, String> environment,
  PlatformHostInterface host,
  ConfigHostInterface policy,
  String? sourcePath,
) {
  if (value is! String || value.trim().isEmpty) {
    throw XcrossConfigException(
      '$field must be a non-empty string',
      path: sourcePath,
    );
  }
  return expandNativeEnvironment(
    value,
    environment: environment,
    host: host,
    policy: policy,
    sourcePath: sourcePath,
  );
}

List<String> _expandedStringList(
  Object? value,
  String field,
  Map<String, String> environment,
  PlatformHostInterface host,
  ConfigHostInterface policy,
  String? sourcePath,
) {
  if (value is! List) {
    throw XcrossConfigException('$field must be a list', path: sourcePath);
  }
  return List.unmodifiable([
    for (var index = 0; index < value.length; index++)
      _expandedString(
        value[index],
        '$field[$index]',
        environment,
        host,
        policy,
        sourcePath,
      ),
  ]);
}

/// Expands native host syntax recursively, with bounded cycle detection.
String expandNativeEnvironment(
  String value, {
  required Map<String, String> environment,
  required PlatformHostInterface host,
  required ConfigHostInterface policy,
  String? sourcePath,
}) {
  rejectUnsafeConfigString(
    value,
    'Configuration value',
    sourcePath: sourcePath,
  );
  final configHost = policy;
  String variable(String name) {
    final replacement = host.environment.lookup(environment, name);
    if (replacement == null) {
      throw XcrossConfigException(
        'Environment variable $name is not defined',
        path: sourcePath,
      );
    }
    rejectUnsafeConfigString(
      replacement,
      'Environment variable $name',
      sourcePath: sourcePath,
    );
    return replacement;
  }

  var result = configHost.expandHome(value, variable);
  final seen = <String>{};
  for (var depth = 0; depth < _maximumEnvironmentExpansionDepth; depth++) {
    if (!seen.add(result)) {
      throw XcrossConfigException(
        'Environment expansion contains a cycle',
        path: sourcePath,
      );
    }
    if (!configHost.variables.hasMatch(result)) return result;
    result = result.replaceAllMapped(
      configHost.variables,
      (match) => variable(match.group(1) ?? match.group(2)!),
    );
  }
  throw XcrossConfigException(
    'Environment expansion exceeded $_maximumEnvironmentExpansionDepth levels or remains unresolved',
    path: sourcePath,
  );
}

void rejectUnsafeConfigString(
  String value,
  String field, {
  String? sourcePath,
}) {
  if (value.contains('\u0000') ||
      value.contains('\n') ||
      value.contains('\r')) {
    throw XcrossConfigException(
      '$field must not contain NUL or newline characters',
      path: sourcePath,
    );
  }
}

final class XcrossConfigValidator {
  const XcrossConfigValidator({
    required this.fileSystem,
    required this.pathContext,
    required this.policy,
  });
  final HostFileSystemInterface fileSystem;
  final p.Context pathContext;
  final ConfigHostInterface policy;

  void validate(XcrossConfig config) {
    _validateRoots(config.roots);
    _validateToolchains(config.toolchains);
    _validateTools(config.tools);
    if (config.setup case final value?) _validateSetupScript(value);
    _validateExcludedCommands(config.excludedCommands);
    _validateEnvironment(config.environment);
  }

  void _validateRoots(XcrossConfigRoots roots) {
    for (final entry in roots.toMap().entries) {
      rejectUnsafeConfigString(entry.value, 'Root ${entry.key}');
      if (!pathContext.isAbsolute(entry.value)) {
        throw XcrossConfigException(
          'Root ${entry.key} must be an absolute path: ${entry.value}',
        );
      }
    }
  }

  void _validateToolchains(XcrossConfigToolchains toolchains) {
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

  void _validateTools(Map<String, String> tools) {
    for (final entry in tools.entries) {
      rejectUnsafeConfigString(entry.key, 'Tool name');
      rejectUnsafeConfigString(entry.value, 'Tool ${entry.key} path');
      if (!pathContext.isAbsolute(entry.value)) {
        throw XcrossConfigException(
          'Tool ${entry.key} must use an absolute path: ${entry.value}',
        );
      }
      final stat = fileSystem.file(entry.value).statSync();
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

  void _validateExcludedCommands(Set<String> excludedCommands) {
    for (final command in excludedCommands) {
      rejectUnsafeConfigString(command, 'Excluded command');
      if (command.isEmpty || command.contains(RegExp(r'\s'))) {
        throw XcrossConfigException(
          'Excluded commands must be non-empty top-level command names: $command',
        );
      }
    }
  }

  void _validateEnvironment(Map<String, Object> environment) {
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

  void _validateSetupScript(String value) {
    rejectUnsafeConfigString(value, 'Setup script');
    if (XcrossConfig.remoteSetupScriptUri(value) == null &&
        !pathContext.isAbsolute(value)) {
      throw XcrossConfigException(
        'Setup script must be an absolute local path or HTTP(S) URL: $value',
      );
    }
  }
}
