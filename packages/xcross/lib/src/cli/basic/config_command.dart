import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:xcross/src/config/config.dart';
import 'package:xcross/src/errors.dart';

typedef ConfigReadLine = String? Function();
typedef ConfigWriteLine = void Function(String value);
typedef ConfigIsInteractive = bool Function();

/// `xcross config` — interactively edit xcross configuration.
final class ConfigCommand extends Command<void> {
  ConfigCommand({
    XcrossConfigStore? store,
    ConfigReadLine? readLine,
    ConfigWriteLine? writeLine,
    ConfigIsInteractive? isInteractive,
  }) : _store = store ?? const XcrossConfigStore(),
       _readLine = readLine ?? stdin.readLineSync,
       _writeLine = writeLine ?? stdout.writeln,
       _isInteractive = isInteractive ?? (() => stdin.hasTerminal);

  final XcrossConfigStore _store;
  final ConfigReadLine _readLine;
  final ConfigWriteLine _writeLine;
  final ConfigIsInteractive _isInteractive;

  @override
  String get name => 'config';

  @override
  String get description =>
      'Create, inspect, and validate xcross configuration.';

  @override
  Future<void> run() async {
    switch (argResults!.rest) {
      case ['show']:
        return ConfigShowCommand(store: _store, writeLine: _writeLine).run();
      case ['validate']:
        return ConfigValidateCommand(
          store: _store,
          writeLine: _writeLine,
        ).run();
      case []:
        break;
      default:
        throw UsageException('Usage: xcross config [show|validate]', usage);
    }
    if (!_isInteractive()) {
      throw XcrossError('Interactive configuration requires a TTY.');
    }
    var config = await _store.load() ?? XcrossConfig();
    var dirty = false;
    while (true) {
      _writeLine(
        '1) Set root  2) Set tool  3) Set toolchain  4) Set environment  '
        '5) List  6) Remove  7) Validate  8) Save  9) Discard  10) Exit',
      );
      final choice = _prompt('Select');
      switch (choice) {
        case '1':
          config = _setRoot(config);
          dirty = true;
        case '2':
          config = _setTool(config);
          dirty = true;
        case '3':
          config = _setToolchain(config);
          dirty = true;
        case '4':
          config = _setEnvironment(config);
          dirty = true;
        case '5':
          _writeLine(config.toYaml());
        case '6':
          config = _remove(config);
          dirty = true;
        case '7':
          config.validate(windows: _store.windows);
          _writeLine('Configuration is valid.');
        case '8':
          config.validate(windows: _store.windows);
          final file = await _store.save(config);
          dirty = false;
          _writeLine('Saved ${file.path}');
        case '9':
          config = await _store.load() ?? XcrossConfig();
          dirty = false;
          _writeLine('Discarded unsaved changes.');
        case '10':
          if (!dirty || _confirmDiscard()) return;
        default:
          _writeLine('Unknown selection.');
      }
    }
  }

  XcrossConfig _setRoot(XcrossConfig config) {
    const names = [
      'darwinSdk',
      'flutterSdk',
      'xcross',
      'javaHome',
      'konanData',
    ];
    _writeLine(
      '1) darwinSdk  2) flutterSdk  3) xcross  4) javaHome  5) konanData',
    );
    final index = int.tryParse(_prompt('Root'));
    if (index == null || index < 1 || index > names.length) {
      _writeLine('Unknown root.');
      return config;
    }
    final name = names[index - 1];
    final value = _prompt(
      '$name absolute path (empty removes)',
      allowEmpty: true,
    );
    final roots = Map<String, String>.from(config.roots.toMap());
    value.isEmpty ? roots.remove(name) : roots[name] = value;
    return _copy(config, roots: roots);
  }

  XcrossConfig _setTool(XcrossConfig config) {
    final name = _prompt('Tool name');
    final value = _prompt('Executable path (empty removes)', allowEmpty: true);
    final tools = Map<String, String>.from(config.tools);
    value.isEmpty
        ? tools.remove(XcrossConfig.normalizeToolName(name))
        : tools[name] = value;
    return XcrossConfig(
      roots: config.roots,
      toolchains: config.toolchains,
      tools: tools,
      environment: config.environment,
    );
  }

  XcrossConfig _setToolchain(XcrossConfig config) {
    final name = _prompt('Toolchain [swift|llvm]').toLowerCase();
    if (name != 'swift' && name != 'llvm') {
      _writeLine('Unknown toolchain.');
      return config;
    }
    final value = _prompt(
      name == 'llvm'
          ? 'Absolute bin directories separated by commas (empty removes)'
          : 'Absolute bin directory (empty removes)',
      allowEmpty: true,
    );
    return XcrossConfig(
      roots: config.roots,
      toolchains: XcrossConfigToolchains(
        swift: name == 'swift'
            ? (value.isEmpty ? null : value)
            : config.toolchains.swift,
        llvm: name == 'llvm'
            ? value
                  .split(',')
                  .map((part) => part.trim())
                  .where((part) => part.isNotEmpty)
                  .toList()
            : config.toolchains.llvm,
      ),
      tools: config.tools,
      environment: config.environment,
    );
  }

  XcrossConfig _setEnvironment(XcrossConfig config) {
    final name = _prompt('Environment key').toUpperCase();
    if (!XcrossConfig.environmentAllowlist.contains(name)) {
      _writeLine('$name is not allowlisted.');
      return config;
    }
    final value = _prompt(
      name == 'PATH'
          ? 'PATH entries separated by commas (empty removes)'
          : 'Value (empty removes)',
      allowEmpty: true,
    );
    final environment = Map<String, Object>.from(config.environment);
    if (value.isEmpty) {
      environment.remove(name);
    } else {
      environment[name] = name == 'PATH'
          ? value
                .split(',')
                .map((part) => part.trim())
                .where((part) => part.isNotEmpty)
                .toList()
          : value;
    }
    return XcrossConfig(
      roots: config.roots,
      toolchains: config.toolchains,
      tools: config.tools,
      environment: environment,
    );
  }

  XcrossConfig _remove(XcrossConfig config) {
    final section = _prompt(
      'Remove [root|tool|toolchain|environment]',
    ).toLowerCase();
    final name = _prompt('Name');
    switch (section) {
      case 'root':
        final roots = Map<String, String>.from(config.roots.toMap())
          ..remove(name);
        return _copy(config, roots: roots);
      case 'tool':
        final tools = Map<String, String>.from(config.tools)
          ..remove(XcrossConfig.normalizeToolName(name));
        return XcrossConfig(
          roots: config.roots,
          toolchains: config.toolchains,
          tools: tools,
          environment: config.environment,
        );
      case 'toolchain':
        return XcrossConfig(
          roots: config.roots,
          toolchains: XcrossConfigToolchains(
            swift: name.toLowerCase() == 'swift'
                ? null
                : config.toolchains.swift,
            llvm: name.toLowerCase() == 'llvm'
                ? const []
                : config.toolchains.llvm,
          ),
          tools: config.tools,
          environment: config.environment,
        );
      case 'environment':
        final environment = Map<String, Object>.from(config.environment)
          ..remove(name.toUpperCase());
        return XcrossConfig(
          roots: config.roots,
          tools: config.tools,
          environment: environment,
        );
      default:
        _writeLine('Unknown section.');
        return config;
    }
  }

  bool _confirmDiscard() {
    _writeLine('Unsaved changes. Exit without saving? [y/N]:');
    final answer = _readLine()?.trim().toLowerCase();
    if (answer == null) throw XcrossError('Configuration input closed.');
    return answer == 'y' || answer == 'yes';
  }

  XcrossConfig _copy(
    XcrossConfig config, {
    required Map<String, String> roots,
  }) => XcrossConfig(
    roots: XcrossConfigRoots(
      darwinSdk: roots['darwinSdk'],
      flutterSdk: roots['flutterSdk'],
      xcross: roots['xcross'],
      javaHome: roots['javaHome'],
      konanData: roots['konanData'],
    ),
    toolchains: config.toolchains,
    tools: config.tools,
    environment: config.environment,
  );

  String _prompt(String label, {bool allowEmpty = false}) {
    _writeLine('$label:');
    final value = _readLine()?.trim();
    if (value == null) throw XcrossError('Configuration input closed.');
    if (!allowEmpty && value.isEmpty) {
      throw XcrossError('$label must not be empty.');
    }
    return value;
  }
}

final class ConfigShowCommand extends Command<void> {
  ConfigShowCommand({XcrossConfigStore? store, ConfigWriteLine? writeLine})
    : _store = store ?? const XcrossConfigStore(),
      _writeLine = writeLine ?? stdout.write;

  final XcrossConfigStore _store;
  final ConfigWriteLine _writeLine;

  @override
  String get name => 'show';

  @override
  String get description => 'Print the selected xcross configuration.';

  @override
  Future<void> run() async {
    final selected = _store.selectedFile();
    final config = await _store.load();
    if (config == null || selected == null) {
      throw XcrossError('No xcross configuration found.');
    }
    _writeLine('Selected: ${selected.path}');
    _writeLine(config.toYaml());
  }
}

final class ConfigValidateCommand extends Command<void> {
  ConfigValidateCommand({XcrossConfigStore? store, ConfigWriteLine? writeLine})
    : _store = store ?? const XcrossConfigStore(),
      _writeLine = writeLine ?? stdout.writeln;

  final XcrossConfigStore _store;
  final ConfigWriteLine _writeLine;

  @override
  String get name => 'validate';

  @override
  String get description => 'Validate the selected xcross configuration.';

  @override
  Future<void> run() async {
    final config = await _store.load();
    if (config == null) throw XcrossError('No xcross configuration found.');
    config.validate(windows: _store.windows);
    _writeLine('Configuration is valid.');
  }
}
