import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/config/config.dart';
import 'package:xcross/src/errors.dart';

typedef ConfigWriteLine = void Function(String value);
typedef ConfigPrompt = String? Function(String label);
typedef ConfigConfirm = bool Function(String label);

enum ConfigTab { roots, toolchains, tools, environment }

final class ConfigTuiController {
  ConfigTuiController(XcrossConfig config) : config = config, _saved = config;

  static const rootNames = [
    'darwinSdk',
    'flutterSdk',
    'xcross',
    'javaHome',
    'konanData',
  ];

  XcrossConfig config;
  XcrossConfig _saved;
  ConfigTab tab = ConfigTab.roots;
  int selection = 0;
  String status = '';

  bool get dirty => config.toYaml() != _saved.toYaml();

  List<MapEntry<String, String>> get _entries => switch (tab) {
    ConfigTab.tools =>
      config.tools.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ConfigTab.environment =>
      config.environment.entries
          .map(
            (entry) => MapEntry(
              entry.key,
              entry.value is List<String>
                  ? (entry.value as List<String>).join(', ')
                  : entry.value as String,
            ),
          )
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    _ => const [],
  };

  int get rowCount => switch (tab) {
    ConfigTab.roots => rootNames.length,
    ConfigTab.toolchains => 2,
    ConfigTab.tools || ConfigTab.environment => _entries.length + 1,
  };

  int get itemCount => rowCount + 4;

  Future<bool> handle(
    TuiKey key, {
    required ConfigPrompt prompt,
    required ConfigConfirm confirm,
    required Future<String> Function(XcrossConfig config) save,
    required void Function(XcrossConfig config) validate,
  }) async {
    try {
      switch (key) {
        case TuiKey.tab || TuiKey.right:
          _switchTab(1);
        case TuiKey.backTab || TuiKey.left:
          _switchTab(-1);
        case TuiKey.up:
          selection = (selection - 1 + itemCount) % itemCount;
        case TuiKey.down:
          selection = (selection + 1) % itemCount;
        case TuiKey.enter:
          if (selection < rowCount) {
            _edit(prompt);
          } else {
            return await _action(selection - rowCount, confirm, save, validate);
          }
        case TuiKey.delete:
          _delete(confirm);
        case TuiKey.save:
          return await _action(0, confirm, save, validate);
        case TuiKey.validate:
          return await _action(1, confirm, save, validate);
        case TuiKey.discard:
          return await _action(2, confirm, save, validate);
        case TuiKey.quit:
          return await _action(3, confirm, save, validate);
        case TuiKey.other:
          break;
      }
    } on Object catch (error) {
      status = error.toString();
    }
    return false;
  }

  void _switchTab(int delta) {
    const tabs = ConfigTab.values;
    tab = tabs[(tab.index + delta + tabs.length) % tabs.length];
    selection = selection.clamp(0, itemCount - 1);
    status = '';
  }

  void _edit(ConfigPrompt prompt) {
    switch (tab) {
      case ConfigTab.roots:
        final roots = Map<String, String>.from(config.roots.toMap());
        final name = rootNames[selection];
        final value = prompt('$name absolute path (empty removes)');
        if (value == null) return;
        value.trim().isEmpty ? roots.remove(name) : roots[name] = value.trim();
        config = _copy(roots: roots);
      case ConfigTab.toolchains:
        final value = prompt(
          selection == 0
              ? 'Swift bin directory (empty removes)'
              : 'LLVM bin directories, comma-separated (empty removes)',
        );
        if (value == null) return;
        config = _copy(
          toolchains: XcrossConfigToolchains(
            swift: selection == 0
                ? (value.trim().isEmpty ? null : value.trim())
                : config.toolchains.swift,
            llvm: selection == 1 ? _split(value) : config.toolchains.llvm,
          ),
        );
      case ConfigTab.tools:
        final entries = _entries;
        if (selection == entries.length) {
          final name = prompt('Tool name')?.trim();
          if (name == null || name.isEmpty) return;
          _setTool(name, prompt('Executable path')?.trim());
        } else {
          final entry = entries[selection];
          _setTool(entry.key, prompt('${entry.key} executable path')?.trim());
        }
      case ConfigTab.environment:
        final entries = _entries;
        if (selection == entries.length) {
          final name = prompt('Environment key')?.trim().toUpperCase();
          if (name == null || name.isEmpty) return;
          if (!XcrossConfig.environmentAllowlist.contains(name)) {
            status = '$name is not allowlisted.';
            return;
          }
          _setEnvironment(name, prompt(_environmentLabel(name))?.trim());
        } else {
          final entry = entries[selection];
          _setEnvironment(
            entry.key,
            prompt(_environmentLabel(entry.key))?.trim(),
          );
        }
    }
  }

  void _setTool(String name, String? value) {
    if (value == null) return;
    final tools = Map<String, String>.from(config.tools);
    final key = XcrossConfig.normalizeToolName(name);
    value.isEmpty ? tools.remove(key) : tools[key] = value;
    config = _copy(tools: tools);
  }

  void _setEnvironment(String name, String? value) {
    if (value == null) return;
    final environment = Map<String, Object>.from(config.environment);
    value.isEmpty
        ? environment.remove(name)
        : environment[name] = name == 'PATH' ? _split(value) : value;
    config = _copy(environment: environment);
  }

  String _environmentLabel(String name) => name == 'PATH'
      ? 'PATH entries, comma-separated (empty removes)'
      : '$name value (empty removes)';

  void _delete(ConfigConfirm confirm) {
    if (selection >= rowCount) return;
    final entries = _entries;
    if ((tab == ConfigTab.tools || tab == ConfigTab.environment) &&
        selection == entries.length) {
      return;
    }
    final name = switch (tab) {
      ConfigTab.roots => rootNames[selection],
      ConfigTab.toolchains => selection == 0 ? 'swift' : 'llvm',
      _ => entries[selection].key,
    };
    if (!confirm('Delete $name? [y/N]')) return;
    switch (tab) {
      case ConfigTab.roots:
        config = _copy(
          roots: Map<String, String>.from(config.roots.toMap())..remove(name),
        );
      case ConfigTab.toolchains:
        config = _copy(
          toolchains: XcrossConfigToolchains(
            swift: selection == 0 ? null : config.toolchains.swift,
            llvm: selection == 1 ? const [] : config.toolchains.llvm,
          ),
        );
      case ConfigTab.tools:
        config = _copy(
          tools: Map<String, String>.from(config.tools)..remove(name),
        );
      case ConfigTab.environment:
        config = _copy(
          environment: Map<String, Object>.from(config.environment)
            ..remove(name),
        );
    }
    selection = selection.clamp(0, itemCount - 1);
  }

  Future<bool> _action(
    int action,
    ConfigConfirm confirm,
    Future<String> Function(XcrossConfig config) save,
    void Function(XcrossConfig config) validate,
  ) async {
    switch (action) {
      case 0:
        validate(config);
        status = 'Saved ${await save(config)}';
        _saved = config;
      case 1:
        validate(config);
        status = 'Configuration is valid.';
      case 2:
        if (dirty && !confirm('Discard unsaved changes? [y/N]')) return false;
        config = _saved;
        status = 'Discarded unsaved changes.';
        selection = selection.clamp(0, itemCount - 1);
      case 3:
        return !dirty || confirm('Unsaved changes. Exit without saving? [y/N]');
    }
    return false;
  }

  XcrossConfig _copy({
    Map<String, String>? roots,
    XcrossConfigToolchains? toolchains,
    Map<String, String>? tools,
    Map<String, Object>? environment,
  }) {
    final values = roots ?? config.roots.toMap();
    return XcrossConfig(
      roots: XcrossConfigRoots(
        darwinSdk: values['darwinSdk'],
        flutterSdk: values['flutterSdk'],
        xcross: values['xcross'],
        javaHome: values['javaHome'],
        konanData: values['konanData'],
      ),
      toolchains: toolchains ?? config.toolchains,
      tools: tools ?? config.tools,
      environment: environment ?? config.environment,
    );
  }

  static List<String> _split(String value) => value
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();

  String render({bool ansi = true, bool color = true}) => AnsiTuiRenderer.frame(
    title: 'xcross config${dirty ? ' *' : ''}',
    tabs: const ['Roots', 'Toolchains', 'Tools', 'Environment'],
    selectedTab: tab.index,
    rows: _renderRows(),
    selection: selection,
    actions: const ['Save', 'Validate', 'Discard', 'Quit'],
    help:
        'Tab/←/→ tabs  ↑/↓ select  Enter edit  Delete remove  s/v/r/q actions',
    status: status,
    ansi: ansi,
    color: color,
  );

  String renderPlainUpdate() {
    final rows = _renderRows();
    const actions = ['Save', 'Validate', 'Discard', 'Quit'];
    final item = selection < rows.length
        ? rows[selection]
        : '[${actions[selection - rows.length]}]';
    return AnsiTuiRenderer.plainUpdate(
      tab: const ['Roots', 'Toolchains', 'Tools', 'Environment'][tab.index],
      item: item,
      status: status,
    );
  }

  List<String> _renderRows() => switch (tab) {
    ConfigTab.roots => [
      for (final name in rootNames)
        '$name: ${config.roots.toMap()[name] ?? '<unset>'}',
    ],
    ConfigTab.toolchains => [
      'swift: ${config.toolchains.swift ?? '<unset>'}',
      'llvm: ${config.toolchains.llvm.isEmpty ? '<unset>' : config.toolchains.llvm.join(', ')}',
    ],
    ConfigTab.tools || ConfigTab.environment => [
      for (final entry in _entries) '${entry.key}: ${entry.value}',
      '+ Add',
    ],
  };
}

final class ConfigCommand extends Command<void> {
  ConfigCommand({
    XcrossConfigStore? store,
    TuiTerminal? terminal,
    ConfigWriteLine? writeLine,
  }) : _store = store ?? const XcrossConfigStore(),
       _terminal = terminal ?? IoTuiTerminal(),
       _writeLine = writeLine ?? stdout.writeln;

  final XcrossConfigStore _store;
  final TuiTerminal _terminal;
  final ConfigWriteLine _writeLine;

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
    if (!_terminal.isInteractive) {
      throw XcrossError('Interactive configuration requires a TTY.');
    }
    final controller = ConfigTuiController(
      await _store.load() ?? XcrossConfig(),
    );
    final tui = AnsiTui(terminal: _terminal);
    await tui.run(
      render: () => controller.render(ansi: tui.useAnsi, color: tui.useColor),
      renderPlainUpdate: controller.renderPlainUpdate,
      handle: (key) => controller.handle(
        key,
        prompt: tui.prompt,
        confirm: tui.confirm,
        save: (config) async => (await _store.save(config)).path,
        validate: (config) => config.validate(windows: _store.windows),
      ),
    );
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
