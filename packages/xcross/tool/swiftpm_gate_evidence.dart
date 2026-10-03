import 'package:xcross/src/composition/xcross_runtime.dart';

Future<void> main(List<String> arguments) async {
  final context = createNativeXcrossContext();
  await context.swiftPmGate.run(arguments);
}
