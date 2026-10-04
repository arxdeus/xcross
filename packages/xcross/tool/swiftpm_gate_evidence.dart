import 'package:xcross/src/composition/native_runtime.dart';

Future<void> main(List<String> arguments) async {
  final context = createNativeXcrossContext();
  await context.swiftPmGate.run(arguments);
}
