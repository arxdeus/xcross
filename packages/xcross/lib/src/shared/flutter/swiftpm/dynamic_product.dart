import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';

/// A dynamic library `swift build` produced (`lib<Product>.dylib`), which the
/// app embeds as `<Product>.framework`, the way Xcode embeds a dynamic
/// SwiftPM product: the App Store rejects a loose dylib in `Frameworks/`
/// (ITMS-90171, TN2435).
///
/// The aggregate `libFlutterPluginsGenerated.dylib` xcross links every
/// SwiftPM plugin into becomes `FlutterPluginsGenerated.framework` too,
/// rather than being linked statically into Runner as Xcode does: the
/// plugin registrant, Swift runtime linkage, and app extensions sharing the
/// plugins all stay as they are, and a framework is a legal bundle layout.
@internal
final class SwiftPmDynamicProduct {
  const SwiftPmDynamicProduct({
    required this.libraryPath,
    required this.packageIdentity,
    this.minimumOsVersion,
  });

  /// The dylib `swift build` left in its products directory.
  final String libraryPath;

  /// The SwiftPM identity of the package declaring the product, as Xcode
  /// names it (a Flutter plugin's versioned directory, see
  /// `flutterPluginSwiftPmIdentities`), or null when unknown.
  final String? packageIdentity;

  /// The package's `MinimumOSVersion` (see
  /// `swiftPmPackageMinimumOsVersion`), or null for the app's.
  final String? minimumOsVersion;

  /// The product name: `lib<Product>.dylib` without `lib` and `.dylib`.
  String get name => swiftPmDynamicProductName(p.basename(libraryPath));

  /// `<Product>.framework`.
  String get frameworkName => '$name.framework';

  /// `@rpath/<Product>.framework/<Product>`.
  String get installName => swiftPmDynamicProductInstallName(name);

  /// Xcode's `CFBundleIdentifier` for the framework of a dynamic product,
  /// `<package identity>.<product>` with every character outside
  /// `[A-Za-z0-9.-]` replaced by `-` (measured with Xcode 26.6:
  /// `flutter-soloud-5.1.2.flutter-soloud`). The aggregate plugins product
  /// gets `flutterpluginsgenerated.FlutterPluginsGenerated`, after Xcode's
  /// `flutterframework.FlutterFramework` for the lowercased package name.
  String get bundleIdentifier =>
      '${packageIdentity ?? name.toLowerCase()}.$name'.replaceAll(
        RegExp('[^A-Za-z0-9.-]'),
        '-',
      );
}

/// The product name of the dylib [basename] (`libflutter-soloud.dylib` gives
/// `flutter-soloud`).
@internal
String swiftPmDynamicProductName(String basename) {
  var name = basename;
  if (name.endsWith('.dylib')) {
    name = name.substring(0, name.length - '.dylib'.length);
  }
  if (name.startsWith('lib') && name.length > 3) name = name.substring(3);
  return name;
}

/// The install name of the framework embedding product [name].
@internal
String swiftPmDynamicProductInstallName(String name) =>
    '@rpath/$name.framework/$name';

/// Whether [manifest] (a `Package.swift`) declares a `.dynamic` library
/// product named [product].
@internal
bool swiftPmDeclaresDynamicLibrary(String manifest, String product) {
  final code = SwiftPmManifestLexer.swiftCodeMask(manifest);
  for (final call in SwiftPmManifestLexer.swiftCalls(manifest, '.library')) {
    if (!code[call.start]) continue;
    if (SwiftPmManifestLexer.namedString(call.text, 'name') != product) {
      continue;
    }
    if (RegExp(r'type\s*:\s*\.dynamic\b').hasMatch(call.text)) return true;
  }
  return false;
}

/// The `Info.plist` Xcode 26.6 writes into the framework of a dynamic
/// SwiftPM product, before the platform and toolchain (`DT*`,
/// `CFBundleSupportedPlatforms`) keys are stamped in: `FMWK`, the product as
/// executable and name, version 1.0 (1), the package's `MinimumOSVersion`
/// (else [deploymentTarget]), `UIDeviceFamily` 1 and 2, and
/// `UIRequiredDeviceCapabilities` `arm64` for device builds only.
@internal
String swiftPmDynamicProductInfoPlist(
  SwiftPmDynamicProduct product, {
  required String deploymentTarget,
  required bool device,
}) {
  String escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final name = escape(product.name);
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
      ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      '<plist version="1.0">\n'
      '<dict>\n'
      '\t<key>CFBundleDevelopmentRegion</key>\n'
      '\t<string>en</string>\n'
      '\t<key>CFBundleExecutable</key>\n'
      '\t<string>$name</string>\n'
      '\t<key>CFBundleIdentifier</key>\n'
      '\t<string>${escape(product.bundleIdentifier)}</string>\n'
      '\t<key>CFBundleInfoDictionaryVersion</key>\n'
      '\t<string>6.0</string>\n'
      '\t<key>CFBundleName</key>\n'
      '\t<string>$name</string>\n'
      '\t<key>CFBundlePackageType</key>\n'
      '\t<string>FMWK</string>\n'
      '\t<key>CFBundleShortVersionString</key>\n'
      '\t<string>1.0</string>\n'
      '\t<key>CFBundleVersion</key>\n'
      '\t<string>1</string>\n'
      '\t<key>MinimumOSVersion</key>\n'
      '\t<string>${product.minimumOsVersion ?? deploymentTarget}</string>\n'
      '\t<key>UIDeviceFamily</key>\n'
      '\t<array>\n'
      '\t\t<integer>1</integer>\n'
      '\t\t<integer>2</integer>\n'
      '\t</array>\n'
      '${device ? '\t<key>UIRequiredDeviceCapabilities</key>\n'
                '\t<array>\n'
                '\t\t<string>arm64</string>\n'
                '\t</array>\n' : ''}'
      '</dict>\n'
      '</plist>\n';
}
