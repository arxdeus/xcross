import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

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
  }) : toolchains = XcrossConfigToolchains(
         swift: toolchains.swift,
         llvm: List.unmodifiable(toolchains.llvm),
       ),
       tools = Map.unmodifiable(_normalizeTools(tools)),
       environment = Map.unmodifiable(_normalizeEnvironment(environment));

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

  String? tool(String name) => tools[normalizeToolName(name)];

  /// Validates paths needed by the configured operations.
  ///
  /// Roots must be absolute, but are not required to exist. Tool overrides must
  /// point to existing regular executable files.
  void validate({bool? windows}) {
    final isWindows = windows ?? Platform.isWindows;
    final pathContext = isWindows ? p.windows : p.posix;
    for (final entry in roots.toMap().entries) {
      _rejectUnsafeString(entry.value, 'Root ${entry.key}');
      if (!pathContext.isAbsolute(entry.value)) {
        throw XcrossConfigException(
          'Root ${entry.key} must be an absolute path: ${entry.value}',
        );
      }
    }
    final toolchainDirectories = <MapEntry<String, String>>[
      if (toolchains.swift case final swift?) MapEntry('swift', swift),
      for (final llvm in toolchains.llvm) MapEntry('llvm', llvm),
    ];
    for (final entry in toolchainDirectories) {
      _rejectUnsafeString(entry.value, 'Toolchain ${entry.key} directory');
      if (!pathContext.isAbsolute(entry.value)) {
        throw XcrossConfigException(
          'Toolchain ${entry.key} must use an absolute bin directory: ${entry.value}',
        );
      }
    }
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
      final executable = isWindows
          ? const {
              '.exe',
              '.com',
              '.bat',
              '.cmd',
            }.contains(p.windows.extension(entry.value).toLowerCase())
          : stat.mode & 0x49 != 0;
      if (!executable) {
        throw XcrossConfigException(
          'Tool ${entry.key} is not executable: ${entry.value}',
        );
      }
    }
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

  static String normalizeToolName(String name) {
    var normalized = name.trim().toLowerCase();
    for (final extension in const ['.exe', '.cmd', '.bat', '.com']) {
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
    String? sourcePath,
    Map<String, String>? environment,
    bool? windows,
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
    final root = _stringMap(document, r'$', sourcePath);
    _onlyKeys(
      root,
      const {'roots', 'toolchains', 'tools', 'environment'},
      r'$',
      sourcePath,
    );
    final env = environment ?? Platform.environment;
    final isWindows = windows ?? Platform.isWindows;
    final rootsNode = root['roots'] == null
        ? <String, Object?>{}
        : _stringMap(root['roots'], r'$.roots', sourcePath);
    _onlyKeys(
      rootsNode,
      const {'darwinSdk', 'flutterSdk', 'xcross', 'javaHome', 'konanData'},
      r'$.roots',
      sourcePath,
    );
    String? rootValue(String key) {
      final value = rootsNode[key];
      if (value == null) return null;
      return _expandedString(
        value,
        r'$.roots.' + key,
        env,
        isWindows,
        sourcePath,
      );
    }

    final toolchainsNode = root['toolchains'] == null
        ? <String, Object?>{}
        : _stringMap(root['toolchains'], r'$.toolchains', sourcePath);
    _onlyKeys(
      toolchainsNode,
      const {'swift', 'llvm'},
      r'$.toolchains',
      sourcePath,
    );
    final swift = toolchainsNode['swift'] == null
        ? null
        : _expandedString(
            toolchainsNode['swift'],
            r'$.toolchains.swift',
            env,
            isWindows,
            sourcePath,
          );
    final llvmValue = toolchainsNode['llvm'];
    final llvm = llvmValue == null
        ? <String>[]
        : llvmValue is String
        ? <String>[
            _expandedString(
              llvmValue,
              r'$.toolchains.llvm',
              env,
              isWindows,
              sourcePath,
            ),
          ]
        : _expandedStringList(
            llvmValue,
            r'$.toolchains.llvm',
            env,
            isWindows,
            sourcePath,
          );

    final toolsNode = root['tools'] == null
        ? <String, Object?>{}
        : _stringMap(root['tools'], r'$.tools', sourcePath);
    final tools = <String, String>{};
    for (final entry in toolsNode.entries) {
      final name = normalizeToolName(entry.key);
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
      tools[name] = _expandedString(
        entry.value,
        r'$.tools.' + entry.key,
        env,
        isWindows,
        sourcePath,
      );
    }

    final environmentNode = root['environment'] == null
        ? <String, Object?>{}
        : _stringMap(root['environment'], r'$.environment', sourcePath);
    final configuredEnvironment = <String, Object>{};
    for (final entry in environmentNode.entries) {
      if (!environmentAllowlist.contains(entry.key)) {
        throw XcrossConfigException(
          'Environment variable ${entry.key} is not allowlisted',
          path: sourcePath,
        );
      }
      configuredEnvironment[entry.key] = entry.key == 'PATH'
          ? _expandedStringList(
              entry.value,
              r'$.environment.PATH',
              env,
              isWindows,
              sourcePath,
            )
          : _expandedString(
              entry.value,
              r'$.environment.' + entry.key,
              env,
              isWindows,
              sourcePath,
            );
    }

    final config = XcrossConfig(
      roots: XcrossConfigRoots(
        darwinSdk: rootValue('darwinSdk'),
        flutterSdk: rootValue('flutterSdk'),
        xcross: rootValue('xcross'),
        javaHome: rootValue('javaHome'),
        konanData: rootValue('konanData'),
      ),
      toolchains: XcrossConfigToolchains(swift: swift, llvm: llvm),
      tools: tools,
      environment: configuredEnvironment,
    );
    config.validate(windows: isWindows);
    return config;
  }

  /// Alias suitable for callers that treat parsing as deserialization.
  static XcrossConfig fromYaml(
    String source, {
    String? sourcePath,
    Map<String, String>? environment,
    bool? windows,
  }) => parse(
    source,
    sourcePath: sourcePath,
    environment: environment,
    windows: windows,
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

/// Discovers, loads, and atomically stores xcross configuration files.
final class XcrossConfigStore {
  const XcrossConfigStore({this.directory, this.environment, this.windows});

  static const selectorVariable = 'XCROSS_CONFIG';
  static const preferredName = 'config.yaml';
  static const fallbackName = 'config.yml';

  final String? directory;
  final Map<String, String>? environment;
  final bool? windows;

  String get defaultDirectory =>
      directory ??
      _platformConfigDirectory(
        environment ?? Platform.environment,
        windows ?? Platform.isWindows,
      );

  File? selectedFile() {
    final env = environment ?? Platform.environment;
    final selector = env[selectorVariable]?.trim();
    if (selector != null && selector.isNotEmpty) return File(selector);
    final yaml = File(p.join(defaultDirectory, preferredName));
    if (yaml.existsSync()) return yaml;
    final yml = File(p.join(defaultDirectory, fallbackName));
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
        windows: windows,
      );
    } on FileSystemException catch (error) {
      throw XcrossConfigException(error.message, path: file.path);
    }
  }

  Future<File> save(XcrossConfig config, {String? path}) async {
    final env = environment ?? Platform.environment;
    final selected = env[selectorVariable]?.trim();
    final target = File(
      path ??
          (selected != null && selected.isNotEmpty
              ? selected
              : selectedFile()?.path ??
                    p.join(defaultDirectory, preferredName)),
    );
    await target.parent.create(recursive: true);
    final temporary = File(
      '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    File? backup;
    try {
      await temporary.writeAsString(config.toYaml(), flush: true);
      if ((windows ?? Platform.isWindows) && target.existsSync()) {
        backup = File(
          '${target.path}.bak-$pid-${DateTime.now().microsecondsSinceEpoch}',
        );
        await target.rename(backup.path);
        try {
          await temporary.rename(target.path);
        } on FileSystemException {
          if (target.existsSync()) await target.delete();
          await backup.rename(target.path);
          backup = null;
          rethrow;
        }
        await backup.delete();
        backup = null;
      } else {
        await temporary.rename(target.path);
      }
    } finally {
      if (temporary.existsSync()) await temporary.delete();
      if (backup != null && backup.existsSync() && !target.existsSync()) {
        await backup.rename(target.path);
      }
    }
    return target;
  }
}

String _platformConfigDirectory(Map<String, String> env, bool windows) {
  if (windows) {
    final base = env['APPDATA'] ?? env['LOCALAPPDATA'] ?? env['USERPROFILE'];
    if (base == null || base.isEmpty) {
      throw const XcrossConfigException(
        'APPDATA, LOCALAPPDATA, or USERPROFILE is required to locate configuration',
      );
    }
    return p.windows.join(base, 'xcross');
  }
  final base = env['XDG_CONFIG_HOME'];
  if (base != null && base.isNotEmpty) return p.posix.join(base, 'xcross');
  final home = env['HOME'];
  if (home == null || home.isEmpty) {
    throw const XcrossConfigException(
      'HOME is required to locate configuration',
    );
  }
  return p.posix.join(home, '.config', 'xcross');
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
  bool windows,
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
    windows: windows,
    sourcePath: sourcePath,
  );
}

List<String> _expandedStringList(
  Object? value,
  String field,
  Map<String, String> environment,
  bool windows,
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
        windows,
        sourcePath,
      ),
  ]);
}

/// Expands native host syntax recursively, with bounded cycle detection.
String expandNativeEnvironment(
  String value, {
  required Map<String, String> environment,
  required bool windows,
  String? sourcePath,
}) {
  _rejectUnsafeString(value, 'Configuration value', sourcePath: sourcePath);
  final pattern = windows
      ? RegExp('%([A-Za-z_][A-Za-z0-9_]*)%')
      : RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)|\$\{([A-Za-z_][A-Za-z0-9_]*)\}');

  String variable(String name) {
    final replacement = environment[name];
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

  var result = value;
  if (!windows && (result == '~' || result.startsWith('~/'))) {
    result = '${variable('HOME')}${result.substring(1)}';
  }
  final seen = <String>{};
  for (var depth = 0; depth < 32; depth++) {
    if (!seen.add(result)) {
      throw XcrossConfigException(
        'Environment expansion contains a cycle',
        path: sourcePath,
      );
    }
    if (!pattern.hasMatch(result)) return result;
    result = result.replaceAllMapped(
      pattern,
      (match) => variable(match.group(1) ?? match.group(2)!),
    );
  }
  throw XcrossConfigException(
    'Environment expansion exceeded 32 levels or remains unresolved',
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
