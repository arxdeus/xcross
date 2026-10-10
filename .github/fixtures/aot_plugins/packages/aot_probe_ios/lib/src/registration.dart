import 'package:aot_probe_platform_interface/aot_probe_platform_interface.dart';

class AotProbeIos extends AotProbePlatform {
  static void registerWith() => AotProbePlatform.instance = AotProbeIos();

  @override
  String describe() => 'ios';
}
