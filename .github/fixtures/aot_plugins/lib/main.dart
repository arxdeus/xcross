import 'package:aot_probe/aot_probe.dart';
import 'package:flutter/material.dart';

void main() => runApp(
  MaterialApp(
    home: Scaffold(
      body: Center(
        child: Text(
          'probe ${describeAotProbe()} '
          '${const String.fromEnvironment('FLUTTER_BUILD_NAME')}',
        ),
      ),
    ),
  ),
);
