import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/swift_package_host_patches.dart';

void main() {
  group('patchFirebaseManifestForCrossHost', () {
    test('enables Firebase source products', () {
      const input = '''
let package = Package(name: "Firebase")
func packageProducts() -> [Product] {
  var products: [Product] = []
  #if os(macOS)
  // Add Apple-only products when building on macOS hosts.
  products.append(.library(name: "FirebaseStorage", targets: ["FirebaseStorage"]))
  #endif // os(macOS)
  return products
}
''';

      final patched = patchFirebaseManifestForCrossHost(input);

      expect(patched, isNot(contains('#if os(macOS)')));
      expect(patched, contains('name: "FirebaseStorage"'));
    });

    test('removes only the guard enclosing the Firebase products', () {
      const input = '''
let package = Package(name: "Firebase")
#if os(macOS)
// Unrelated macOS-only configuration.
let unrelated = true
#endif // os(macOS)
func packageProducts() -> [Product] {
  var products: [Product] = []
  #if os(macOS)
  // Add Apple-only products when building on macOS hosts.
  products.append(.library(name: "FirebaseStorage", targets: ["FirebaseStorage"]))
  #endif // os(macOS)
  return products
}
''';

      final patched = patchFirebaseManifestForCrossHost(input);

      expect(patched, contains('#if os(macOS)\n// Unrelated'));
      expect(patched, contains('#endif // os(macOS)\nfunc packageProducts'));
      expect(patched, contains('name: "FirebaseStorage"'));
      expect(patchFirebaseManifestForCrossHost(patched), patched);
    });

    test('leaves unrelated manifests unchanged', () {
      const manifest = '''
let package = Package(name: "Other")
#if os(macOS)
// Add Apple-only products when building on macOS hosts.
#endif // os(macOS)
''';

      expect(patchFirebaseManifestForCrossHost(manifest), manifest);
    });
  });
}
