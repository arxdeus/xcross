import 'package:aot_probe_platform_interface/aot_probe_platform_interface.dart';

String describeAotProbe() => AotProbePlatform.instance?.describe() ?? 'none';
