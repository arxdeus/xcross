import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/compose/swift/swift_host_paths.dart';

void main() {
  const root = '/work/proj';
  bool host(String relative) =>
      isSwiftHostSource(p.join(root, relative), projectRoot: root);

  test('accepts Swift sources of the iosApp host', () {
    expect(host('iosApp/App.swift'), isTrue);
    expect(host('iosApp/KmpSwiftApp/Views/ContentView.swift'), isTrue);
  });

  test('rejects previews, test targets and dependency checkouts', () {
    expect(host('iosApp/App/Preview Content/P.swift'), isFalse);
    expect(host('iosApp/AppTests/T.swift'), isFalse);
    expect(host('iosApp/AppUITests/U.swift'), isFalse);
    expect(host('iosApp/Pods/Lib/L.swift'), isFalse);
    expect(host('iosApp/Carthage/Build/C.swift'), isFalse);
  });

  test('rejects non-Swift files and Swift outside iosApp', () {
    expect(host('iosApp/App.kt'), isFalse);
    expect(host('shared/src/iosMain/X.swift'), isFalse);
    expect(host('App.swift'), isFalse);
  });

  test('ignores directories above the project root', () {
    // A project checked out under e.g. ~/IntegrationTests/ must still have
    // its host sources discovered and watched.
    const nested = '/home/me/IntegrationTests/proj';
    expect(
      isSwiftHostSource(
        p.join(nested, 'iosApp', 'App.swift'),
        projectRoot: nested,
      ),
      isTrue,
    );
  });
}
