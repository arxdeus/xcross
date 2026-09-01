import 'dart:io';

import 'package:xcross/xcross.dart';

Future<void> main(List<String> args) async {
  final aliasCode = await runPreparedToolAlias(args);
  if (aliasCode != null) exit(aliasCode);

  await XcrossRuntimeConfig.initialize();
  final code = await XcrossCli.run(args);
  exit(code);
}
