import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/runner_shim.dart';

void main() {
  test('always records the first rendered Flutter frame', () {
    final source = RunnerShim.runnerObjcSource(
      hasPlugins: true,
      verbose: false,
    );

    expect(source, contains('[xcross] first Flutter frame rendered'));
    expect(
      source,
      contains('[[UIWindow alloc] initWithWindowScene:windowScene]'),
    );
    expect(source, contains('self.window = window'));
    expect(source, isNot(contains('[[UIScreen mainScreen] bounds]')));
    expect(source, isNot(contains('application launch started')));
    expect(source, isNot(contains('Flutter engine initialized')));
  });

  test('creates Flutter UI from the scene lifecycle', () {
    final source = RunnerShim.runnerObjcSource(
      hasPlugins: true,
      verbose: false,
    );
    final appDelegate = source.substring(
      source.indexOf('@implementation AppDelegate'),
      source.indexOf('@interface SceneDelegate'),
    );
    final sceneDelegate = source.substring(
      source.indexOf('@implementation SceneDelegate'),
      source.indexOf('int main'),
    );

    expect(appDelegate, isNot(contains('FlutterViewController')));
    expect(appDelegate, isNot(contains('UIWindow')));
    expect(sceneDelegate, contains('willConnectToSession'));
    expect(sceneDelegate, contains('initWithWindowScene:windowScene'));
    expect(sceneDelegate, contains('self.window = window'));
    expect(sceneDelegate, contains('[super scene:scene'));
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
