import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:xcross/src/constants.dart';

/// Plist / xcconfig text manipulation for the generated app bundle.
///
/// Pure string transforms (plus one filesystem probe for compiled
/// storyboards); no state, no I/O beyond that probe.
abstract final class InfoPlist {
  /// Overwrite or insert all mandatory iOS bundle keys.
  /// Version strings (CFBundleShortVersionString / CFBundleVersion) are NOT
  /// forced here — they come solely from $(FLUTTER_BUILD_NAME) /
  /// $(FLUTTER_BUILD_NUMBER) substitution so that xcconfig and --build-name
  /// values are respected.
  static String applyIosRequiredKeys(
    String plistXml, {
    required String bundleId,
  }) {
    var xml = plistXml;
    xml = _setPlistKey(xml, 'CFBundleExecutable', PlistDefaults.executable);
    xml = _setPlistKey(xml, 'CFBundleIdentifier', bundleId);
    xml = _setPlistKey(xml, 'CFBundlePackageType', 'APPL');
    if (!xml.contains(IosDeploymentConstants.minimumOsVersionKey)) {
      xml = _setPlistKey(
        xml,
        IosDeploymentConstants.minimumOsVersionKey,
        IosDeploymentConstants.minDeploymentTarget,
      );
    }
    xml = _ensureKey(
      xml,
      'LSRequiresIPhoneOS',
      '\t<key>LSRequiresIPhoneOS</key>\n\t<true/>\n',
    );
    xml = _ensureKey(
      xml,
      'CFBundleSupportedPlatforms',
      '\t<key>CFBundleSupportedPlatforms</key>\n'
          '\t<array><string>iPhoneOS</string></array>\n',
    );
    xml = _ensureKey(
      xml,
      'UIRequiredDeviceCapabilities',
      '\t<key>UIRequiredDeviceCapabilities</key>\n'
          '\t<array><string>arm64</string></array>\n',
    );
    // Xcode injects these at build time; without them newer iOS (26+) refuses
    // to register the app with SpringBoard/LaunchServices (installs but won't
    // launch — FBSApplicationLibrary returns nil).
    xml = _ensureKey(
      xml,
      'UIDeviceFamily',
      '\t<key>UIDeviceFamily</key>\n'
          '\t<array><integer>1</integer></array>\n',
    );
    xml = _ensureKey(
      xml,
      'DTPlatformName',
      '\t<key>DTPlatformName</key>\n\t<string>iphoneos</string>\n',
    );
    xml = _ensureKey(
      xml,
      'DTSDKName',
      '\t<key>DTSDKName</key>\n'
          '\t<string>${IosDeploymentConstants.sdkTriple}</string>\n',
    );
    xml = _ensureKey(
      xml,
      'DTPlatformVersion',
      '\t<key>DTPlatformVersion</key>\n'
          '\t<string>${IosDeploymentConstants.sdkVersion}</string>\n',
    );
    return xml;
  }

  /// Insert [fragment] before `</dict>` if [needle] is absent from [xml].
  static String _ensureKey(String xml, String needle, String fragment) {
    if (xml.contains(needle)) {
      return xml;
    }
    return _insertBeforeEnd(xml, fragment);
  }

  /// Expand `$(KEY)` and `${KEY}` in [text] using [subs].
  static String expandVars(String text, Map<String, String> subs) {
    var result = text;
    for (final entry in subs.entries) {
      result = result
          .replaceAll('\$(${entry.key})', entry.value)
          .replaceAll('\${${entry.key}}', entry.value);
    }
    return result;
  }

  /// Parse `KEY = VALUE` lines from an Xcode `.xcconfig` file.
  /// Strips `[config]` suffixes (e.g. `KEY[debug] = VALUE`).
  static Map<String, String> parseXcconfig(String text) {
    final result = <String, String>{};
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('//') || line.startsWith('#')) {
        continue;
      }
      final eq = line.indexOf('=');
      if (eq < 0) continue;
      var key = line.substring(0, eq).trim();
      final bracket = key.indexOf('[');
      if (bracket >= 0) key = key.substring(0, bracket).trim();
      final value = line.substring(eq + 1).trim();
      result[key] = value;
    }
    return result;
  }

  /// Overwrite an existing `<key>K</key><string>…</string>` pair, or insert a
  /// new one before `</dict>` if the key is absent.
  static String _setPlistKey(String xml, String key, String value) {
    final pattern =
        RegExp('<key>$key</key>\\s*<string>[^<]*</string>', dotAll: true);
    final replacement = '<key>$key</key>\n\t<string>$value</string>';
    if (xml.contains('<key>$key</key>')) {
      return xml.replaceFirst(pattern, replacement);
    }
    return _insertBeforeEnd(xml, '\t$replacement\n');
  }

  /// Insert [fragment] before the closing `</dict>` of the root plist dict.
  /// Tries `</dict>\n</plist>` first (canonical), then falls back to the last
  /// bare `</dict>` to handle compact plist serialisations.
  static String _insertBeforeEnd(String xml, String fragment) {
    const sentinel = '</dict>\n</plist>';
    final idx = xml.lastIndexOf(sentinel);
    if (idx >= 0) {
      return xml.substring(0, idx) + fragment + xml.substring(idx);
    }
    const dictEnd = '</dict>';
    final dictIdx = xml.lastIndexOf(dictEnd);
    if (dictIdx >= 0) {
      return xml.substring(0, dictIdx) + fragment + xml.substring(dictIdx);
    }
    return xml + fragment;
  }

  /// Remove references to storyboards not present (compiled) in [bundleDir].
  /// xtool doesn't run `ibtool`, so missing storyboards would crash at launch.
  static String stripUnsatisfiableStoryboards(String xml, String bundleDir) {
    bool hasCompiled(String name) =>
        Directory(p.join(bundleDir, '$name.storyboardc')).existsSync();

    // Named local reused by Main and Scene patterns (identical predicate).
    String keepIfCompiled(Match m) =>
        hasCompiled(m.group(1)!) ? m.group(0)! : '';

    var result = xml.replaceAllMapped(
      _uiMainStoryboardPattern,
      keepIfCompiled,
    );

    result = result.replaceAllMapped(
      _uiLaunchStoryboardPattern,
      (m) {
        if (hasCompiled(m.group(1)!)) {
          return m.group(0)!;
        }
        // Replace with UILaunchScreen programmatic launch screen if absent.
        // Reads the pre-launch-strip snapshot of `result` on purpose: hoisting
        // this check or chaining the replaceAllMapped calls changes which
        // snapshot is inspected and can emit a duplicate UILaunchScreen.
        if (!result.contains('UILaunchScreen')) {
          return '<key>UILaunchScreen</key>\n\t<dict/>';
        }
        return '';
      },
    );

    result = result.replaceAllMapped(
      _uiSceneStoryboardPattern,
      keepIfCompiled,
    );

    return result;
  }

  /// Drop Swift module prefix from ObjC class names in the plist.
  /// The Runner shim registers `AppDelegate` / `SceneDelegate` without a module
  /// prefix, so `Runner.SceneDelegate` from the stock template would fail
  /// `NSClassFromString`.
  static String normalizeObjCClassNames(String xml) {
    return xml.replaceAllMapped(
      _objcClassNamePattern,
      (m) {
        final name = m.group(2)!;
        final dot = name.lastIndexOf('.');
        final unqualified = dot >= 0 ? name.substring(dot + 1) : name;
        return '${m.group(1)}$unqualified${m.group(3)}';
      },
    );
  }

  static final _uiMainStoryboardPattern = RegExp(
    r'<key>UIMainStoryboardFile</key>\s*<string>([^<]*)</string>',
  );

  static final _uiLaunchStoryboardPattern = RegExp(
    r'<key>UILaunchStoryboardName</key>\s*<string>([^<]*)</string>',
  );

  static final _uiSceneStoryboardPattern = RegExp(
    r'<key>UISceneStoryboardFile</key>\s*<string>([^<]*)</string>',
  );

  static final _objcClassNamePattern = RegExp(
    r'(<key>(?:UISceneDelegateClassName|NSPrincipalClass)</key>\s*<string>)'
    '([^<]*)'
    '(</string>)',
  );

  /// Minimal plist used when the project has no `ios/Runner/Info.plist`.
  static const fallback = '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
      ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      '<plist version="1.0">\n'
      '<dict>\n'
      '\t<key>UILaunchScreen</key>\n'
      '\t<dict/>\n'
      '\t<key>UISupportedInterfaceOrientations</key>\n'
      '\t<array>\n'
      '\t\t<string>UIInterfaceOrientationPortrait</string>\n'
      '\t</array>\n'
      '</dict>\n'
      '</plist>\n';
}
