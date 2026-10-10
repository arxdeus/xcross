import 'dart:io';

import 'package:aot_probe_platform_interface/aot_probe_platform_interface.dart';

class AotProbeOther extends AotProbePlatform {
  static void registerWith() => AotProbePlatform.instance = AotProbeOther();

  @override
  String describe() => '${Platform.operatingSystem} ${Platform.version}';
}
