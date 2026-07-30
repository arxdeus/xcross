import 'dart:io';

import 'package:xcross/xcross.dart';

Future<void> main(List<String> args) async {
  final code = await runXcross(args);
  // Exit explicitly rather than falling off the end of main: a single lingering
  // handle (a Timer, a signal subscription, a listening socket) keeps the Dart
  // event loop alive and the process hangs after all work is done. That has
  // bitten this tool repeatedly. Flush first — exit() does not wait for pending
  // async writes.
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
