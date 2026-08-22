import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/ide/subcommands/vscode_json_merge.dart';
import 'package:xcross/src/cli/ide/xcross_executable.dart';

/// `xcross ide idea` — write a shared LSP4IJ DAP run configuration that
/// drives `xcross flutter dap` (stdio).
final class IdeaCommand extends Command<void> {
  @override
  String get name => 'idea';

  @override
  String get description =>
      'Set up a JetBrains DAP run config so Debug runs on an iOS device.';

  @override
  Future<void> run() async {
    final exe = resolveXcrossExecutable(
      subcommand: 'idea',
      brokenFeature: 'Debug',
    );

    final dir = Directory(p.join(Directory.current.path, '.run'));
    await dir.create(recursive: true);

    await _writeIfAbsent(
      p.join(dir.path, 'xcross_ios_device.run.xml'),
      buildIdeaRunXml(exe),
    );

    Log.logInfo(
      'Next',
      Log.dim(
        'install LSP4IJ (plugins.jetbrains.com/plugin/23257-lsp4ij), '
        'then Debug the "xcross: iOS device" run configuration '
        "(not Flutter's Run button)",
      ),
    );
  }

  /// Never clobber a run config the user may have edited; print it instead.
  static Future<void> _writeIfAbsent(String path, String content) async {
    final file = File(path);
    if (file.existsSync()) {
      Log.logWarn(
        '${p.relative(path)} already exists — merge this in yourself:\n'
        '$content',
      );
      return;
    }
    await file.writeAsString(content);
    Log.logDone('Wrote ${p.relative(path)}');
  }

  /// Shared `.run/*.run.xml` body for LSP4IJ's `DAPConfiguration` type.
  static String buildIdeaRunXml(String xcrossExe) {
    final command = '${_quoteCmd(xcrossExe)} flutter dap';
    final launch = jsonEncode({
      'type': 'dart',
      'name': 'xcross: iOS device',
      'request': 'launch',
      'program': 'lib/main.dart',
      'cwd': r'${workspaceFolder}',
      'env': {xcrossEnvKey: xcrossEnvValue},
      'args': <String>[],
    });

    return '''
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="xcross: iOS device" type="DAPConfiguration" factoryName="DAPConfiguration">
    <option name="command" value="${_xmlAttr(command)}" />
    <option name="connectTimeout" value="0" />
    <option name="debugMode" value="LAUNCH" />
    <option name="debugServerWaitStrategy" value="TIMEOUT" />
    <option name="file" value="\$PROJECT_DIR\$/lib/main.dart" />
    <option name="workingDirectory" value="\$PROJECT_DIR\$" />
    <option name="serverId" value="" />
    <option name="serverName" value="xcross" />
    <option name="launchConfiguration" value="${_xmlAttr(launch)}" />
    <option name="serverMappings">
      <list>
        <ServerMappingSettings>
          <option name="fileNamePatterns">
            <list>
              <option value="*.dart" />
            </list>
          </option>
          <fileType>
            <FileTypeSettings>
              <option name="patterns">
                <option value="*.dart" />
              </option>
            </FileTypeSettings>
          </fileType>
        </ServerMappingSettings>
      </list>
    </option>
    <method v="2" />
  </configuration>
</component>
''';
  }

  /// LSP4IJ splits `command` on whitespace, so a path containing any must be
  /// quoted before it is embedded.
  static String _quoteCmd(String path) => path.contains(RegExp(r'[\s"]'))
      ? '"${path.replaceAll('"', r'\"')}"'
      : path;

  static String _xmlAttr(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('"', '&quot;');
}
