import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/runner_shim.dart';

void main() {
  test('always records the first rendered Flutter frame', () {
    final source = RunnerShim.runnerObjcSource(
      hasPlugins: true,
      verbose: false,
    );

    expect(source, contains('[xcross] first Flutter frame rendered'));
    expect(source, isNot(contains('application launch started')));
    expect(source, isNot(contains('Flutter engine initialized')));
  });

  test('verbose source records native launch and engine phases', () {
    final source = RunnerShim.runnerObjcSource(hasPlugins: true, verbose: true);

    expect(source, contains('[xcross] application launch started'));
    expect(
      source,
      contains('[xcross] FlutterAppDelegate didFinishLaunching returned: %@'),
    );
    expect(
      source,
      contains('[xcross] Flutter engine initialized; registering plugins'),
    );
    expect(source, contains('[xcross] plugin registration completed'));
  });

  test('verbose source summarizes an app without native plugins', () {
    final source = RunnerShim.runnerObjcSource(
      hasPlugins: false,
      verbose: true,
    );

    expect(
      source,
      contains(
        '[xcross] plugin registration summary: '
        '0 attempted, 0 registered, 0 failed',
      ),
    );
  });
}
