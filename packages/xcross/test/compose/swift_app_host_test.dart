import 'package:test/test.dart';
import 'package:xcross/src/shared/compose/kmp_entry_discovery.dart';

void main() {
  bool host(String s) => KmpEntryDiscovery.isSwiftAppHost(s);
  group('isSwiftAppHost', () {
    for (final s in [
      '@main struct X: App { }',
      '@main\npublic struct X: App { }',
      '@main public final class X: App { }',
      '@main @MainActor struct X: App { }',
      '@main enum X: App { }',
      '@available(iOS 17, *)\n@main\nstruct X: App { }',
      '@main @available(iOS 17, *) struct X: SwiftUI.App { }',
      '@main struct X: Sendable, App { }',
      '@main struct X<T>: App where T: Any { }',
    ]) {
      test('detects $s', () => expect(host(s), isTrue));
    }
    for (final s in [
      '@main class D: UIResponder, UIApplicationDelegate { }',
      '@main struct X: MyApp { }',
      '@main struct X: AppDelegate { }',
      '// @main struct X: App {}',
      '/* @main struct X: App {} */',
      'let s = "@main struct X: App {}"',
      'struct X: App { }',
    ]) {
      test('rejects $s', () => expect(host(s), isFalse));
    }
  });
}
