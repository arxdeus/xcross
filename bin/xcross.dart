import 'dart:io';

import 'package:xcross/xcross.dart';

Future<void> main(List<String> args) async {
  exitCode = await runXcross(args);
}
