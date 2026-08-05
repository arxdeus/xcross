import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;

/// Absolute xcross binary path to embed in generated IDE configs.
///
/// Captured now so a later PATH change cannot break the editor. Under
/// `dart run` the resolved executable is the Dart VM, which the IDE cannot
/// use to start xcross — warn instead of silently writing a dead config.
String resolveXcrossExecutable({
  required String subcommand,
  required String brokenFeature,
}) {
  final exe = Platform.resolvedExecutable;
  if (p.basenameWithoutExtension(exe) != 'xcross') {
    Log.logWarn(
      'embedding $exe — run `xcross ide $subcommand` from the installed '
      'binary, not `dart run`, or $brokenFeature will not work',
    );
  }
  return exe;
}
