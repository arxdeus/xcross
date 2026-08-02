import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/util/logging.dart';

/// `xcross ide idea` — write a shared LSP4IJ DAP run configuration that
/// drives `xcross dap` (stdio).
class IdeaCommand extends Command<void> {
  @override
  String get name => 'idea';

  @override
  String get description =>
      'Set up a JetBrains DAP run config so Debug runs on an iOS device.';

  @override
  Future<void> run() async {
    final exe = Platform.resolvedExecutable;
    if (p.basenameWithoutExtension(exe) != 'xcross') {
      Log.logWarn(
        'embedding $exe — run `xcross ide idea` from the installed '
        'binary, not `dart run`, or Debug will not work',
      );
    }

    final dir = Directory(p.join(Directory.current.path, '.run'));
    await dir.create(recursive: true);

    final path = p.join(dir.path, 'xcross_ios_device.run.xml');
    await _writeIfAbsent(path, buildIdeaRunXml(exe));

    Log.logInfo(
      'Next',
      Log.ansi.subtle(
        'install LSP4IJ (plugins.jetbrains.com/plugin/18229-lsp4ij), '
        'then Debug the "xcross: iOS device" run configuration '
        "(not Flutter's Run button)",
      ),
    );
  }

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
}

/// Shared `.run/*.run.xml` body for LSP4IJ's `DAPConfiguration` type.
String buildIdeaRunXml(String xcrossExe) {
  final command = '${_quoteCmd(xcrossExe)} dap';
  final launch = jsonEncode({
    'type': 'dart',
    'name': 'xcross: iOS device',
    'request': 'launch',
    'program': 'lib/main.dart',
    'cwd': r'${workspaceFolder}',
    'xcross': true,
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
          <fileType>
            <option name="patterns">
              <list>
                <option value="*.dart" />
              </list>
            </option>
          </fileType>
        </ServerMappingSettings>
      </list>
    </option>
    <method v="2" />
  </configuration>
</component>
''';
}

String _quoteCmd(String path) {
  if (path.contains(RegExp(r'[\s"]'))) {
    return '"${path.replaceAll('"', r'\"')}"';
  }
  return path;
}

String _xmlAttr(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('"', '&quot;');
