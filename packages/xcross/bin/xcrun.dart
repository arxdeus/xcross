import 'dart:io';

import 'package:xcross/src/composition/native_runtime.dart';

Future<void> main(List<String> arguments) async {
  var code = 0;
  try {
    final context = createNativeXcrossContext();
    code = await context.xcrun.run(arguments);
  } on Object catch (error) {
    stderr.writeln('xcrun: $error');
    code = 1;
  }
  try {
    await Future.wait([stdout.flush(), stderr.flush()])
        .timeout(const Duration(seconds: 2));
  } on Object {
    // Best effort; never block termination on a wedged stream.
  }
  exit(code);
}
