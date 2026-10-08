import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/tui/tui.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/config/config.dart';

@internal
typedef ConfigPrompt = String? Function(String label);
@internal
typedef ConfigConfirm = bool Function(String label);

@internal
enum ConfigTab { roots, toolchains, tools, environment, setup, commands }

@internal
enum ConfigAction { save, validate, discard, quit }

@internal
enum ConfigToolchain { swift, llvm }

@internal
enum ConfigRoot { darwinSdk, flutterSdk, xcross, javaHome, konanData }

extension on ConfigTab {
  String get label => switch (this) {
    ConfigTab.roots => 'Roots',
    ConfigTab.toolchains => 'Toolchains',
    ConfigTab.tools => 'Tools',
    ConfigTab.environment => 'Environment',
    ConfigTab.setup => 'Setup',
    ConfigTab.commands => 'Commands',
  };
}

extension on ConfigAction {
  String get label => switch (this) {
    ConfigAction.save => 'Save',
    ConfigAction.validate => 'Validate',
    ConfigAction.discard => 'Discard',
    ConfigAction.quit => 'Quit',
  };
}

@internal
final class ConfigTuiController {
  ConfigTuiController(XcrossConfig config, {required this.paths})
    : config = config,
      _saved = config;

  final HostPathsInterface paths;
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
    ConfigTab.setup => const [],
    ConfigTab.commands => [
      for (final command in config.excludedCommands.toList()..sort())
        MapEntry(command, 'excluded'),
    ],
    _ => const [],
  };

  int get rowCount => switch (tab) {
    ConfigTab.roots => ConfigRoot.values.length,
    ConfigTab.toolchains => ConfigToolchain.values.length,
    ConfigTab.setup => 1,
    ConfigTab.tools ||
    ConfigTab.environment ||
    ConfigTab.commands => _entries.length + 1,
  };

  int get itemCount => rowCount + ConfigAction.values.length;

  Future<bool> handle(
    TuiKey key, {
    required ConfigPrompt prompt,
    required ConfigConfirm confirm,
    required Future<String> Function(XcrossConfig config) save,
    required void Function(XcrossConfig config) validate,
  }) async {
    Future<bool> perform(ConfigAction action) =>
        _performAction(action, confirm, save, validate);
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
            _editSelectedRow(prompt);
          } else {
            return await perform(ConfigAction.values[selection - rowCount]);
          }
        case TuiKey.delete:
          _deleteSelectedRow(confirm);
        case TuiKey.save:
          return await perform(ConfigAction.save);
        case TuiKey.validate:
          return await perform(ConfigAction.validate);
        case TuiKey.discard:
          return await perform(ConfigAction.discard);
        case TuiKey.quit:
          return await perform(ConfigAction.quit);
        case TuiKey.other:
          break;
      }
    } on XcrossConfigException catch (error) {
      status = error.toString();
    } on FileSystemException catch (error) {
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

  void _editSelectedRow(ConfigPrompt prompt) {
    switch (tab) {
      case ConfigTab.roots:
        _editRoot(prompt);
      case ConfigTab.toolchains:
        _editToolchain(prompt);
      case ConfigTab.tools:
        _editTool(prompt);
      case ConfigTab.environment:
        _editEnvironment(prompt);
      case ConfigTab.setup:
        _editSetup(prompt);
      case ConfigTab.commands:
        _editExcludedCommand(prompt);
    }
  }

  void _editRoot(ConfigPrompt prompt) {
    final root = ConfigRoot.values[selection];
    final value = prompt('${root.name} absolute path (empty removes)');
    if (value == null) return;
    final path = value.trim().isEmpty ? null : value.trim();
    final roots = switch (root) {
      ConfigRoot.darwinSdk => config.roots.copyWith(darwinSdk: path),
      ConfigRoot.flutterSdk => config.roots.copyWith(flutterSdk: path),
      ConfigRoot.xcross => config.roots.copyWith(xcross: path),
      ConfigRoot.javaHome => config.roots.copyWith(javaHome: path),
      ConfigRoot.konanData => config.roots.copyWith(konanData: path),
    };
    config = config.copyWith(roots: roots);
  }

  void _editToolchain(ConfigPrompt prompt) {
    final toolchain = ConfigToolchain.values[selection];
    final value = prompt(switch (toolchain) {
      ConfigToolchain.swift => 'Swift bin directory (empty removes)',
      ConfigToolchain.llvm =>
        'LLVM bin directories, comma-separated (empty removes)',
    });
    if (value == null) return;
    config = config.copyWith(
      toolchains: switch (toolchain) {
        ConfigToolchain.swift => XcrossConfigToolchains(
          swift: value.trim().isEmpty ? null : value.trim(),
          llvm: config.toolchains.llvm,
        ),
        ConfigToolchain.llvm => XcrossConfigToolchains(
          swift: config.toolchains.swift,
          llvm: _split(value),
        ),
      },
    );
  }

  void _editTool(ConfigPrompt prompt) {
    final entries = _entries;
    if (selection == entries.length) {
      final name = prompt('Tool name')?.trim();
      if (name == null || name.isEmpty) return;
      _setTool(name, prompt('Executable path')?.trim());
    } else {
      final entry = entries[selection];
      _setTool(entry.key, prompt('${entry.key} executable path')?.trim());
    }
  }

  void _editEnvironment(ConfigPrompt prompt) {
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
      _setEnvironment(entry.key, prompt(_environmentLabel(entry.key))?.trim());
    }
  }

  void _editSetup(ConfigPrompt prompt) {
    final value = prompt(
      'Setup script absolute path or HTTP(S) URL (empty removes)',
    );
    if (value == null) return;
    config = config.copyWith(setup: value.trim().isEmpty ? null : value.trim());
  }

  void _editExcludedCommand(ConfigPrompt prompt) {
    final entries = _entries;
    final command = prompt(
      selection == entries.length
          ? 'Command to exclude'
          : 'Excluded command name (empty removes)',
    )?.trim().toLowerCase();
    if (command == null) return;
    final commands = config.excludedCommands.toSet();
    if (selection < entries.length) commands.remove(entries[selection].key);
    if (command.isNotEmpty) commands.add(command);
    config = config.copyWith(excludedCommands: commands);
  }

  void _setTool(String name, String? value) {
    if (value == null) return;
    final tools = Map<String, String>.from(config.tools);
    final key = paths.toolNameKey(name);
    value.isEmpty ? tools.remove(key) : tools[key] = value;
    config = config.copyWith(tools: tools);
  }

  void _setEnvironment(String name, String? value) {
    if (value == null) return;
    final environment = Map<String, Object>.from(config.environment);
    value.isEmpty
        ? environment.remove(name)
        : environment[name] = name == 'PATH' ? _split(value) : value;
    config = config.copyWith(environment: environment);
  }

  String _environmentLabel(String name) => name == 'PATH'
      ? 'PATH entries, comma-separated (empty removes)'
      : '$name value (empty removes)';

  void _deleteSelectedRow(ConfigConfirm confirm) {
    if (selection >= rowCount) return;
    final entries = _entries;
    if ((tab == ConfigTab.tools ||
            tab == ConfigTab.environment ||
            tab == ConfigTab.commands) &&
        selection == entries.length) {
      return;
    }
    final name = switch (tab) {
      ConfigTab.roots => ConfigRoot.values[selection].name,
      ConfigTab.toolchains => ConfigToolchain.values[selection].name,
      ConfigTab.setup => 'setup',
      _ => entries[selection].key,
    };
    if (!confirm('Delete $name? [y/N]')) return;
    switch (tab) {
      case ConfigTab.roots:
        final root = ConfigRoot.values[selection];
        final roots = switch (root) {
          ConfigRoot.darwinSdk => config.roots.copyWith(darwinSdk: null),
          ConfigRoot.flutterSdk => config.roots.copyWith(flutterSdk: null),
          ConfigRoot.xcross => config.roots.copyWith(xcross: null),
          ConfigRoot.javaHome => config.roots.copyWith(javaHome: null),
          ConfigRoot.konanData => config.roots.copyWith(konanData: null),
        };
        config = config.copyWith(roots: roots);
      case ConfigTab.toolchains:
        config = config.copyWith(
          toolchains: switch (ConfigToolchain.values[selection]) {
            ConfigToolchain.swift => XcrossConfigToolchains(
              llvm: config.toolchains.llvm,
            ),
            ConfigToolchain.llvm => XcrossConfigToolchains(
              swift: config.toolchains.swift,
            ),
          },
        );
      case ConfigTab.tools:
        config = config.copyWith(
          tools: Map<String, String>.from(config.tools)..remove(name),
        );
      case ConfigTab.environment:
        config = config.copyWith(
          environment: Map<String, Object>.from(config.environment)
            ..remove(name),
        );
      case ConfigTab.setup:
        config = config.copyWith(setup: null);
      case ConfigTab.commands:
        config = config.copyWith(
          excludedCommands: config.excludedCommands.toSet()..remove(name),
        );
    }
    selection = selection.clamp(0, itemCount - 1);
  }

  Future<bool> _performAction(
    ConfigAction action,
    ConfigConfirm confirm,
    Future<String> Function(XcrossConfig config) save,
    void Function(XcrossConfig config) validate,
  ) async {
    switch (action) {
      case ConfigAction.save:
        validate(config);
        status = 'Saved ${await save(config)}';
        _saved = config;
      case ConfigAction.validate:
        validate(config);
        status = 'Configuration is valid.';
      case ConfigAction.discard:
        if (dirty && !confirm('Discard unsaved changes? [y/N]')) return false;
        config = _saved;
        status = 'Discarded unsaved changes.';
        selection = selection.clamp(0, itemCount - 1);
      case ConfigAction.quit:
        return !dirty || confirm('Unsaved changes. Exit without saving? [y/N]');
    }
    return false;
  }

  static List<String> _split(String value) => value
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();

  String render({bool ansi = true, bool color = true}) => AnsiTuiRenderer.frame(
    title: 'xcross config${dirty ? ' *' : ''}',
    tabs: ConfigTab.values.map((tab) => tab.label).toList(),
    selectedTab: tab.index,
    rows: _renderRows(),
    selection: selection,
    actions: ConfigAction.values.map((action) => action.label).toList(),
    help:
        'Tab/←/→ tabs  ↑/↓ select  Enter edit  Delete remove  s/v/r/q actions',
    status: status,
    ansi: ansi,
    color: color,
  );

  String renderPlainUpdate() {
    final rows = _renderRows();
    final actions = ConfigAction.values.map((action) => action.label).toList();
    final item = selection < rows.length
        ? rows[selection]
        : '[${actions[selection - rows.length]}]';
    return AnsiTuiRenderer.plainUpdate(
      tab: tab.label,
      item: item,
      status: status,
    );
  }

  List<String> _renderRows() => switch (tab) {
    ConfigTab.roots => [
      for (final root in ConfigRoot.values)
        '${root.name}: ${config.roots.toMap()[root.name] ?? '<unset>'}',
    ],
    ConfigTab.toolchains => [
      'swift: ${config.toolchains.swift ?? '<unset>'}',
      'llvm: ${config.toolchains.llvm.isEmpty ? '<unset>' : config.toolchains.llvm.join(', ')}',
    ],
    ConfigTab.tools || ConfigTab.environment => [
      for (final entry in _entries) '${entry.key}: ${entry.value}',
      '+ Add',
    ],
    ConfigTab.setup => ['script: ${config.setup ?? '<unset>'}'],
    ConfigTab.commands => [for (final entry in _entries) entry.key, '+ Add'],
  };
}
