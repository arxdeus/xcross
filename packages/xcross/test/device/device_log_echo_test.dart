import 'package:test/test.dart';
import 'package:xcross/src/target/iphone/device/device_log.dart';

void main() {
  String? echo(String message, {bool verbose = false, bool dart = false}) =>
      DeviceLog.echoLine(message, verbose: verbose, dartOutput: dart);

  test('shows Dart output without the engine tag', () {
    expect(echo('flutter: hello', dart: true), 'hello');
    expect(echo('flutter: ', dart: true), '');
    expect(echo('flutter:  indented', dart: true), ' indented');
  });

  test('keeps framework chatter quiet', () {
    expect(echo('nw_resolver_start_query', dart: true), isNull);
    expect(echo('[FirebaseAnalytics] started', dart: true), isNull);
    expect(echo('Flutter: not the engine tag', dart: true), isNull);
    expect(echo('message mentioning flutter: inline', dart: true), isNull);
  });

  test('shows nothing when Dart output arrives over the VM Service', () {
    expect(echo('flutter: hello'), isNull);
  });

  test('verbose shows every app line, tagged and unstripped', () {
    expect(echo('flutter: hello', verbose: true), '[device] flutter: hello');
    expect(
      echo('nw_resolver_start_query', verbose: true, dart: true),
      '[device] nw_resolver_start_query',
    );
  });
}
