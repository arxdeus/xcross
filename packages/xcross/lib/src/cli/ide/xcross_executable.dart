import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;

/// Absolute xcross binary path to embed in generated IDE configs.
///
/// Captured now so a later PATH change cannot break the editor. Under
/// `dart run` the resolved executable is the Dart VM, which the IDE cannot
/// use to start xcross — warn instead of silently writing a dead config.
///
/// Under Nix, `Platform.resolvedExecutable` resolves through the
/// `makeWrapper` script's `exec` straight to the unwrapped binary at
/// `.../lib/xcross/bin/xcross`, which breaks the expected environment setup.
String resolveXcrossExecutable({
  required String subcommand,
  required String brokenFeature,
}) {
  var exe = Platform.resolvedExecutable;

  if (p.basenameWithoutExtension(exe) != 'xcross') {
    Log.logWarn(
      'embedding $exe — run `xcross ide $subcommand` from the installed '
      'binary, not `dart run`, or $brokenFeature will not work',
    );
    return exe;
  }

  if (exe.contains('${p.separator}nix${p.separator}store${p.separator}')) {
    final wrapped = p.normalize(
      p.join(p.dirname(exe), '..', '..', '..', 'bin', p.basename(exe)),
    );
    if (File(wrapped).existsSync()) {
      exe = wrapped;
    } else {
      Log.logWarn(
        'embedding $exe from a Nix store path, but the expected wrapper '
        'at $wrapped was not found — $brokenFeature may not work correctly',
      );
    }
  }

  return exe;
}
