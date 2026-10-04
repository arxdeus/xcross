import 'dart:io';

import 'package:xcross/src/composition/native_runtime.dart';

Future<void> main(List<String> arguments) async {
  try {
    final context = createNativeXcrossContext();
    exitCode = await context.xcrun.run(arguments);
  } on Object catch (error) {
    stderr.writeln('xcrun: $error');
    exitCode = 1;
  }
}
