import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;

String? _launcherOverride;
String? _configPathOverride;
String? _flutterRootOverride;
bool _declarative = false;

/// Configures the launcher embedded in generated IDE configs.
void configureXcrossLauncherOverride(
  String? launcher, {
  String? configPath,
  String? flutterRoot,
  bool declarative = false,
}) {
  _launcherOverride = launcher;
  _configPathOverride = configPath;
  _flutterRootOverride = flutterRoot;
  _declarative = declarative;
}

/// Selector environment to persist in generated IDE processes.
Map<String, String> get generatedIdeEnvironment => {
  if (_configPathOverride case final path?) 'XCROSS_CONFIG': path,
  if (_flutterRootOverride case final root?) 'FLUTTER_ROOT': root,
};

/// Whether generated IDE launchers may inherit the editor's environment.
bool get inheritIdeParentEnvironment => !_declarative;

/// Removes the configured IDE launcher override.
void resetXcrossLauncherOverride() {
  _launcherOverride = null;
  _configPathOverride = null;
  _flutterRootOverride = null;
  _declarative = false;
}

/// Absolute xcross binary path to embed in generated IDE configs.
///
/// Captured now so a later PATH change cannot break the editor. Under
/// `dart run` the resolved executable is the Dart VM, which the IDE cannot
/// use to start xcross — warn instead of silently writing a dead config.
String resolveXcrossExecutable({
  required String subcommand,
  required String brokenFeature,
}) {
  final exe = _launcherOverride ?? Platform.resolvedExecutable;

  if (p.basenameWithoutExtension(exe) != 'xcross') {
    Log.logWarn(
      'embedding $exe — run `xcross ide $subcommand` from the installed '
      'binary, not `dart run`, or $brokenFeature will not work',
    );
    return exe;
  }

  return exe;
}
