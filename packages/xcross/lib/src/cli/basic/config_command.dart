import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/cli/basic/config_tui_controller.dart';
import 'package:xcross/src/config/config.dart';
import 'package:xcross/src/config/config_decoder.dart';
import 'package:xcross/src/errors.dart';

export 'package:xcross/src/cli/basic/config_tui_controller.dart';

typedef ConfigWriteLine = void Function(String value);

final class ConfigCommand extends Command<void> {
  ConfigCommand({
    required XcrossConfigStore store,
    required TuiTerminal terminal,
    required ConfigWriteLine writeLine,
    Map<String, String>? terminalEnvironment,
  }) : _validator = XcrossConfigValidator(
         fileSystem: store.host.fileSystem,
         pathContext: store.host.paths.context,
         policy: store.policy,
       ),
       _store = store,
       _terminal = terminal,
       _writeLine = writeLine,
       _terminalEnvironment =
           terminalEnvironment ?? store.host.environment.values;

  final XcrossConfigValidator _validator;
  final XcrossConfigStore _store;
  final TuiTerminal _terminal;
  final ConfigWriteLine _writeLine;
  final Map<String, String> _terminalEnvironment;

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
    final tui = AnsiTui(terminal: _terminal, environment: _terminalEnvironment);
    await tui.run(
      render: () => controller.render(ansi: tui.useAnsi, color: tui.useColor),
      renderPlainUpdate: controller.renderPlainUpdate,
      handle: (key) => controller.handle(
        key,
        prompt: tui.prompt,
        confirm: tui.confirm,
        save: (config) async => (await _store.save(config)).path,
        validate: _validator.validate,
      ),
    );
  }
}

final class ConfigShowCommand extends Command<void> {
  ConfigShowCommand({
    required XcrossConfigStore store,
    required ConfigWriteLine writeLine,
  }) : _store = store,
       _writeLine = writeLine;

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
    _writeLine(config.toYaml().trimRight());
  }
}

final class ConfigValidateCommand extends Command<void> {
  ConfigValidateCommand({
    required XcrossConfigStore store,
    required ConfigWriteLine writeLine,
  }) : _validator = XcrossConfigValidator(
         fileSystem: store.host.fileSystem,
         pathContext: store.host.paths.context,
         policy: store.policy,
       ),
       _store = store,
       _writeLine = writeLine;

  final XcrossConfigValidator _validator;
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
    _validator.validate(config);
    _writeLine('Configuration is valid.');
  }
}
