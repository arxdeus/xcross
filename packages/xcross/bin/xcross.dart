import 'dart:io';

import 'package:xcross/xcross.dart';

Future<void> main(List<String> args) async {
  final aliasCode = await runPreparedToolAlias(args);
  if (aliasCode != null) exit(aliasCode);

  try {
    await XcrossRuntimeConfig.initialize();
  } on Object catch (error, stackTrace) {
    stderr.writeln(XcrossCli.formatFailure(error, stackTrace));
    exit(1);
  }
  final code = await XcrossCli.run(args);
  exit(code);
}
