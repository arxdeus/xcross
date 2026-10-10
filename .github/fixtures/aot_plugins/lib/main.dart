import 'package:aot_probe/aot_probe.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const _buildName = String.fromEnvironment('FLUTTER_BUILD_NAME');
const _buildNumber = String.fromEnvironment('FLUTTER_BUILD_NUMBER');
const _mode = kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug');

Future<void> main() async {
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(child: Text('probe ${describeAotProbe()} $_buildName')),
      ),
    ),
  );
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  debugPrint(
    'XCROSS_AOT_READY mode=$_mode probe=${describeAotProbe()} '
    'build=$_buildName+$_buildNumber',
  );
}
