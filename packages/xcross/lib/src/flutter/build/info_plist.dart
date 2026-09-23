import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/required_plist_key.dart';
import 'package:xcross/src/flutter/build/internal/xcconfig_resolver.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/constants.dart';
import 'package:xml/xml.dart';

/// Plist / xcconfig text manipulation for the generated app bundle.
///
/// Pure string transforms (plus one filesystem probe for compiled
/// storyboards); no state, no I/O beyond that probe.
abstract final class InfoPlist {
  /// Overwrite `CFBundleIdentifier` (used when qualifying the App ID at
  /// device-sign time).
  static String setBundleIdentifier(String plistXml, String bundleId) =>
      _setPlistKey(plistXml, 'CFBundleIdentifier', bundleId);

  /// Set an arbitrary string key, inserting it when absent.
  static String setPlistString(String plistXml, String key, String value) =>
      _setPlistKey(plistXml, key, value);

  /// Read `CFBundleIdentifier`, or null when absent.
  static String? readBundleIdentifier(String plistXml) {
    final match = RegExp(
      r'<key>CFBundleIdentifier</key>\s*<string>([^<]*)</string>',
    ).firstMatch(plistXml);
    final value = match?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Replace [from] with [to] inside `CFBundleURLSchemes` values only.
  ///
  /// Schemes are conventionally derived from the bundle id
  /// (`ShareMedia-<bundle id>`), so qualifying the App ID at sign time also
  /// has to qualify the scheme, or the extension's redirect back into the
  /// app resolves to a scheme nothing has registered.
  ///
  /// The rewrite is deliberately confined to the scheme arrays: replacing
  /// [from] across the whole plist would also rewrite unrelated keys that
  /// legitimately mention the original bundle id.
  static String rewriteUrlSchemes(
    String plistXml, {
    required String from,
    required String to,
  }) {
    if (from == to || from.isEmpty) return plistXml;

    final arrays = RegExp(
      r'(<key>\s*CFBundleURLSchemes\s*</key>\s*<array>)(.*?)(</array>)',
      dotAll: true,
    );
    return plistXml.replaceAllMapped(arrays, (match) {
      final body = match
          .group(2)!
          .replaceAllMapped(
            RegExp('<string>([^<]*)</string>'),
            (scheme) =>
                '<string>${scheme.group(1)!.replaceAll(from, to)}</string>',
          );
      return '${match.group(1)}$body${match.group(3)}';
    });
  }

  /// Keys Xcode would inject at build time, added only when the template
  /// doesn't already declare them, in this exact order.
  ///
  /// The `UIDeviceFamily`/`DT*` group matters on iOS 26+: without it the OS
  /// refuses to register the app with SpringBoard/LaunchServices (it installs
  /// but won't launch — FBSApplicationLibrary returns nil).
  static const _requiredKeys = <RequiredPlistKey>[
    RequiredPlistKey(key: 'LSRequiresIPhoneOS', value: '<true/>'),
    RequiredPlistKey(
      key: 'CFBundleSupportedPlatforms',
      value: '<array><string>iPhoneOS</string></array>',
    ),
    RequiredPlistKey(
      key: 'UIRequiredDeviceCapabilities',
      value: '<array><string>arm64</string></array>',
    ),
    RequiredPlistKey(
      key: 'UIDeviceFamily',
      value: '<array><integer>1</integer></array>',
    ),
    RequiredPlistKey(key: 'DTPlatformName', value: '<string>iphoneos</string>'),
    RequiredPlistKey(
      key: 'DTSDKName',
      value: '<string>${IosDeploymentConstants.sdkTriple}</string>',
    ),
    RequiredPlistKey(
      key: 'DTPlatformVersion',
      value: '<string>${IosDeploymentConstants.sdkVersion}</string>',
    ),
  ];

  /// Overwrite or insert all mandatory iOS bundle keys.
  ///
  /// Version strings (CFBundleShortVersionString / CFBundleVersion) are NOT
  /// forced here — they come solely from $(FLUTTER_BUILD_NAME) /
  /// $(FLUTTER_BUILD_NUMBER) substitution so that xcconfig and --build-name
  /// values are respected.
  static String applyIosRequiredKeys(
    String plistXml, {
    required String bundleId,
    required IosDeploymentTarget deploymentTarget,
  }) {
    var xml = _setPlistKey(
      plistXml,
      'CFBundleExecutable',
      PlistDefaults.executable,
    );
    xml = setBundleIdentifier(xml, bundleId);
    xml = _setPlistKey(xml, 'CFBundlePackageType', 'APPL');
    xml = _setPlistKey(
      xml,
      IosDeploymentConstants.minimumOsVersionKey,
      deploymentTarget.version,
    );
    for (final entry in _requiredKeys) {
      if (xml.contains(entry.key)) continue;
      xml = _insertBeforeEnd(
        xml,
        '\t<key>${entry.key}</key>\n\t${entry.value}\n',
      );
    }
    return xml;
  }

  /// Add the Debug-only local-network declarations Flutter's Xcode backend
  /// writes into the produced app bundle for the Dart VM Service.
  ///
  /// xcross packs debug/JIT bundles without Xcode, so this mirrors
  /// `xcode_backend.dart` rather than requiring every application template to
  /// carry development-only permission text in its source Info.plist.
  static String applyDebugVmServiceDiscovery(String plistXml) {
    final document = XmlDocument.parse(plistXml);
    final root = document.rootElement.getElement('dict');
    if (root == null) {
      throw const FormatException('Info.plist has no root dict');
    }

    final currentServices = _plistValueFor(root, _bonjourServicesKey);
    if (currentServices != null && currentServices.name.local != 'array') {
      throw const FormatException('NSBonjourServices must be an array');
    }
    final currentUsage = _plistValueFor(root, _localNetworkUsageKey);
    if (currentUsage != null && currentUsage.name.local != 'string') {
      throw const FormatException(
        'NSLocalNetworkUsageDescription must be a string',
      );
    }
    final hasVmService =
        currentServices != null && _containsVmService(currentServices);
    if (hasVmService && currentUsage != null) return plistXml;

    final services = currentServices ?? _plistElement('array');
    if (currentServices == null) {
      root.children
        ..add(_plistElement('key', _bonjourServicesKey))
        ..add(services);
    }
    if (!hasVmService) {
      services.children.add(_plistElement('string', _dartVmService));
    }
    if (currentUsage == null) {
      root.children
        ..add(_plistElement('key', _localNetworkUsageKey))
        ..add(_plistElement('string', _debugLocalNetworkUsage));
    }
    return document.toXmlString();
  }

  static const _dartVmService = '_dartVmService._tcp';
  static const _bonjourServicesKey = 'NSBonjourServices';
  static const _localNetworkUsageKey = 'NSLocalNetworkUsageDescription';
  static const _debugLocalNetworkUsage =
      'Allow Flutter tools on your computer to connect and debug '
      'your application. This prompt will not appear on release builds.';

  /// The value element following `<key>[name]</key>` in [dict], or null.
  static XmlElement? _plistValueFor(XmlElement dict, String name) {
    final entries = dict.childElements.toList();
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].name.local == 'key' && entries[i].innerText == name) {
        if (i + 1 >= entries.length || entries[i + 1].name.local == 'key') {
          throw FormatException('Info.plist key $name has no value');
        }
        return entries[i + 1];
      }
    }
    return null;
  }

  static bool _containsVmService(XmlElement services) =>
      services.childElements.any(
        (entry) =>
            entry.name.local == 'string' && entry.innerText == _dartVmService,
      );

  static XmlElement _plistElement(String name, [String? text]) =>
      XmlElement(XmlName.parts(name), [], [if (text != null) XmlText(text)]);

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

  /// Substitute plist values through XML nodes so authored xcconfig values
  /// containing `&`, `<`, or quotes remain valid XML.
  static String expandXmlVars(String xml, Map<String, String> subs) {
    final document = XmlDocument.parse(xml);
    for (final node in document.descendants) {
      if (node is XmlText) {
        node.value = expandVars(node.value, subs);
      } else if (node is XmlElement) {
        for (final attribute in node.attributes) {
          attribute.value = expandVars(attribute.value, subs);
        }
      }
    }
    return document.toXmlString();
  }

  /// Compatibility entry point for evaluating one xcconfig text value.
  static Map<String, String> parseXcconfig(
    String text, {
    String configuration = 'Debug',
    String sdk = 'iphoneos',
    String arch = 'arm64',
  }) => XcconfigResolver.parseText(
    text,
    configuration: configuration,
    sdk: sdk,
    arch: arch,
  );

  /// Compatibility entry point for ordered xcconfig file evaluation.
  static Future<Map<String, String>> readXcconfigFiles(
    Iterable<String> paths, {
    String configuration = 'Debug',
    String sdk = 'iphoneos',
    String arch = 'arm64',
  }) => XcconfigResolver.readFiles(
    paths,
    configuration: configuration,
    sdk: sdk,
    arch: arch,
  );

  /// Overwrite an existing `<key>K</key><string>…</string>` pair, or insert a
  /// new one before `</dict>` if the key is absent.
  static String _setPlistKey(String xml, String key, String value) {
    final pattern = RegExp(
      '<key>$key</key>\\s*<string>[^<]*</string>',
      dotAll: true,
    );
    final replacement = '<key>$key</key>\n\t<string>$value</string>';
    if (xml.contains('<key>$key</key>')) {
      // Every occurrence, not just the first: a template that declares the
      // same key twice (hand-edited plists do) would otherwise keep a stale
      // second copy, and CFBundle resolves duplicates to the *last* one, so
      // the value actually read back at runtime would be the one left behind.
      return xml.replaceAll(pattern, replacement);
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
  /// xcross doesn't run `ibtool`, so missing storyboards would crash at launch.
  static String stripUnsatisfiableStoryboards(String xml, String bundleDir) {
    bool hasCompiled(String name) =>
        Directory(p.join(bundleDir, '$name.storyboardc')).existsSync();

    // Named local reused by Main and Scene patterns (identical predicate).
    String keepIfCompiled(Match m) =>
        hasCompiled(m.group(1)!) ? m.group(0)! : '';

    var result = xml.replaceAllMapped(_uiMainStoryboardPattern, keepIfCompiled);

    result = result.replaceAllMapped(_uiLaunchStoryboardPattern, (m) {
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
    });

    result = result.replaceAllMapped(_uiSceneStoryboardPattern, keepIfCompiled);

    return result;
  }

  static String applySceneLifecycle(String xml) {
    const manifestKey = '<key>UIApplicationSceneManifest</key>';
    final manifestKeyStart = xml.indexOf(manifestKey);
    if (manifestKeyStart < 0) return _insertBeforeEnd(xml, _sceneManifest);

    final manifest = _containerAfterKey(
      xml,
      manifestKeyStart,
      manifestKey,
      'dict',
    );
    if (manifest == null) return xml;
    if (manifest.selfClosing) {
      return xml.replaceRange(
        manifestKeyStart,
        manifest.end,
        _sceneManifest.trimRight(),
      );
    }

    const roleKey = '<key>UIWindowSceneSessionRoleApplication</key>';
    final roleKeyStart = xml.indexOf(roleKey, manifest.start);
    if (roleKeyStart >= 0 && roleKeyStart < manifest.end) {
      final role = _containerAfterKey(xml, roleKeyStart, roleKey, 'array');
      if (role != null && role.end <= manifest.end) {
        return xml.replaceRange(
          roleKeyStart,
          role.end,
          _applicationSceneConfiguration.trim(),
        );
      }
    }

    const configurationsKey = '<key>UISceneConfigurations</key>';
    final configurationsKeyStart = xml.indexOf(
      configurationsKey,
      manifest.start,
    );
    if (configurationsKeyStart >= 0 && configurationsKeyStart < manifest.end) {
      final configurations = _containerAfterKey(
        xml,
        configurationsKeyStart,
        configurationsKey,
        'dict',
      );
      if (configurations != null && configurations.end <= manifest.end) {
        if (configurations.selfClosing) {
          return xml.replaceRange(
            configurations.start,
            configurations.end,
            '<dict>\n$_applicationSceneConfiguration\t\t</dict>',
          );
        }
        return xml.replaceRange(
          configurations.end - '</dict>'.length,
          configurations.end - '</dict>'.length,
          _applicationSceneConfiguration,
        );
      }
    }

    return xml.replaceRange(
      manifest.end - '</dict>'.length,
      manifest.end - '</dict>'.length,
      '\t\t<key>UISceneConfigurations</key>\n'
      '\t\t<dict>\n'
      '$_applicationSceneConfiguration'
      '\t\t</dict>\n',
    );
  }

  static ({int start, int end, bool selfClosing})? _containerAfterKey(
    String xml,
    int keyStart,
    String key,
    String tag,
  ) {
    final valueStart = keyStart + key.length;
    final value = RegExp('\\s*<$tag(/?)>').matchAsPrefix(xml, valueStart);
    if (value == null) return null;
    if (value.group(1) == '/') {
      return (start: value.start, end: value.end, selfClosing: true);
    }

    var depth = 0;
    for (final match in RegExp('</?$tag>').allMatches(xml, value.start)) {
      if (match.group(0) == '<$tag>') {
        depth++;
      } else if (--depth == 0) {
        return (start: value.start, end: match.end, selfClosing: false);
      }
    }
    return null;
  }

  static const _applicationSceneConfiguration =
      '\t\t\t<key>UIWindowSceneSessionRoleApplication</key>\n'
      '\t\t\t<array>\n'
      '\t\t\t\t<dict>\n'
      '\t\t\t\t\t<key>UISceneClassName</key>\n'
      '\t\t\t\t\t<string>UIWindowScene</string>\n'
      '\t\t\t\t\t<key>UISceneDelegateClassName</key>\n'
      '\t\t\t\t\t<string>SceneDelegate</string>\n'
      '\t\t\t\t\t<key>UISceneConfigurationName</key>\n'
      '\t\t\t\t\t<string>flutter</string>\n'
      '\t\t\t\t</dict>\n'
      '\t\t\t</array>\n';

  static const _sceneManifest =
      '\t<key>UIApplicationSceneManifest</key>\n'
      '\t<dict>\n'
      '\t\t<key>UIApplicationSupportsMultipleScenes</key>\n'
      '\t\t<false/>\n'
      '\t\t<key>UISceneConfigurations</key>\n'
      '\t\t<dict>\n'
      '$_applicationSceneConfiguration'
      '\t\t</dict>\n'
      '\t</dict>\n';

  /// Drop Swift module prefix from ObjC class names in the plist.
  /// The Runner shim registers `AppDelegate` / `SceneDelegate` without a module
  /// prefix, so `Runner.SceneDelegate` from the stock template would fail
  /// `NSClassFromString`.
  static String normalizeObjCClassNames(String xml) {
    return xml.replaceAllMapped(_objcClassNamePattern, (m) {
      final name = m.group(2)!;
      final dot = name.lastIndexOf('.');
      final unqualified = dot >= 0 ? name.substring(dot + 1) : name;
      return '${m.group(1)}$unqualified${m.group(3)}';
    });
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
  static const fallback =
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
      ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      '<plist version="1.0">\n'
      '<dict>\n'
      '$_sceneManifest'
      '\t<key>UILaunchScreen</key>\n'
      '\t<dict/>\n'
      '\t<key>UISupportedInterfaceOrientations</key>\n'
      '\t<array>\n'
      '\t\t<string>UIInterfaceOrientationPortrait</string>\n'
      '\t</array>\n'
      '</dict>\n'
      '</plist>\n';
}
