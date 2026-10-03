import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/shared/config/config_host.dart';
import 'package:xcross/src/composition/config_host.dart';
import 'package:yaml/yaml.dart';

const _notProvided = _NotProvided();
const _windowsExecutableExtensions = {'.exe', '.com', '.bat', '.cmd'};
const _maximumEnvironmentExpansionDepth = 32;

final class _NotProvided {
  const _NotProvided();
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
    ConfigHostInterface? policy,
  }) {
    final configHost = policy ?? configHostPolicy(host);
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
      _rejectUnsafeString(entry.value, 'Root ${entry.key}');
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
      _rejectUnsafeString(entry.value, 'Toolchain ${entry.key} directory');
      if (!pathContext.isAbsolute(entry.value)) {
        throw XcrossConfigException(
          'Toolchain ${entry.key} must use an absolute bin directory: ${entry.value}',
        );
      }
    }
  }

  void _validateTools(p.Context pathContext, ConfigHostInterface policy) {
    for (final entry in tools.entries) {
      _rejectUnsafeString(entry.key, 'Tool name');
      _rejectUnsafeString(entry.value, 'Tool ${entry.key} path');
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
      _rejectUnsafeString(command, 'Excluded command');
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
          _rejectUnsafeString(value, 'Environment ${entry.key} entry');
          if (!pathContext.isAbsolute(value)) {
            throw XcrossConfigException(
              'Environment ${entry.key} entries must be absolute paths: $value',
            );
          }
        }
      } else {
        _rejectUnsafeString(entry.value as String, 'Environment ${entry.key}');
      }
    }
  }

  static Uri? remoteSetupScriptUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.scheme == 'https' || uri.scheme == 'http' ? uri : null;
  }

  static void _validateSetupScript(String value, p.Context pathContext) {
    _rejectUnsafeString(value, 'Setup script');
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

  // A named factory would misleadingly imply this never validates or throws.
  // ignore: prefer_constructors_over_static_methods
  static XcrossConfig parse(
    String source, {
    required PlatformHostInterface host,
    String? sourcePath,
    Map<String, String>? environment,
    ConfigHostInterface? policy,
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
    return _ConfigDecoder(
      document: document,
      sourcePath: sourcePath,
      environment: environment ?? host.environment.values,
      host: host,
      policy: policy ?? configHostPolicy(host),
    ).decode();
  }

  /// Alias suitable for callers that treat parsing as deserialization.
  static XcrossConfig fromYaml(
    String source, {
    required PlatformHostInterface host,
    String? sourcePath,
    Map<String, String>? environment,
    ConfigHostInterface? policy,
  }) => parse(
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
      _rejectUnsafeString(entry.key, 'Environment variable name');
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
          _rejectUnsafeString(value, 'Environment PATH entry');
        }
        result[entry.key] = List<String>.unmodifiable(paths);
      } else if (entry.value is String &&
          (entry.value as String).trim().isNotEmpty) {
        _rejectUnsafeString(
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
      _rejectUnsafeString(entry.key, 'Tool name');
      if (key.isEmpty || result.containsKey(key)) {
        throw XcrossConfigException(
          'Invalid or duplicate tool name: ${entry.key}',
        );
      }
      _rejectUnsafeString(entry.value, 'Tool path for ${entry.key}');
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

final class _ConfigDecoder {
  const _ConfigDecoder({
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
    config.validate(host: host, policy: policy);
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

/// Discovers, loads, and atomically stores xcross configuration files.
final class XcrossConfigStore<T extends PlatformHostInterface> {
  XcrossConfigStore(
    this.host, {
    this.directory,
    Map<String, String>? environment,
    ConfigHostInterface? policy,
  }) : environment = Map.unmodifiable(environment ?? host.environment.values),
       policy = policy ?? configHostPolicy(host);

  static const selectorVariable = 'XCROSS_CONFIG';
  static const preferredName = 'config.yaml';
  static const fallbackName = 'config.yml';

  final T host;
  final String? directory;
  final Map<String, String> environment;
  final ConfigHostInterface policy;

  String get defaultDirectory =>
      directory ?? host.paths.context.join(host.paths.configRoot, 'xcross');

  File? selectedFile() {
    final selector = host.environment
        .lookup(environment, selectorVariable)
        ?.trim();
    if (selector != null && selector.isNotEmpty)
      return host.fileSystem.file(selector);
    final yaml = host.fileSystem.file(
      host.paths.context.join(defaultDirectory, preferredName),
    );
    if (yaml.existsSync()) return yaml;
    final yml = host.fileSystem.file(
      host.paths.context.join(defaultDirectory, fallbackName),
    );
    return yml.existsSync() ? yml : null;
  }

  Future<XcrossConfig?> load() async {
    final file = selectedFile();
    if (file == null) return null;
    if (!file.existsSync()) {
      throw XcrossConfigException(
        'Selected configuration does not exist',
        path: file.path,
      );
    }
    try {
      return XcrossConfig.parse(
        await file.readAsString(),
        sourcePath: file.path,
        environment: environment,
        host: host,
        policy: policy,
      );
    } on FileSystemException catch (error) {
      throw XcrossConfigException(error.message, path: file.path);
    }
  }

  Future<File> save(XcrossConfig config, {String? path}) async {
    final selected = host.environment
        .lookup(environment, selectorVariable)
        ?.trim();
    final target = host.fileSystem.file(
      path ??
          (selected != null && selected.isNotEmpty
              ? selected
              : selectedFile()?.path ??
                    host.paths.context.join(defaultDirectory, preferredName)),
    );
    await target.parent.create(recursive: true);
    final temporary = host.fileSystem.file(
      '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(config.toYaml(), flush: true);
      await policy.replace(temporary, target);
    } finally {
      if (temporary.existsSync()) await temporary.delete();
    }
    return target;
  }
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
  ConfigHostInterface? policy,
  String? sourcePath,
}) {
  _rejectUnsafeString(value, 'Configuration value', sourcePath: sourcePath);
  final configHost = policy ?? configHostPolicy(host);
  String variable(String name) {
    final replacement = host.environment.lookup(environment, name);
    if (replacement == null) {
      throw XcrossConfigException(
        'Environment variable $name is not defined',
        path: sourcePath,
      );
    }
    _rejectUnsafeString(
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

void _rejectUnsafeString(String value, String field, {String? sourcePath}) {
  if (value.contains('\u0000') ||
      value.contains('\n') ||
      value.contains('\r')) {
    throw XcrossConfigException(
      '$field must not contain NUL or newline characters',
      path: sourcePath,
    );
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
