import 'package:xcross/src/shared/artifact/plist_mutations.dart';
import 'package:xcross/src/shared/artifact/plist_xml.dart';
import 'package:xcross/src/shared/flutter/build/internal/required_plist_key.dart';
import 'package:xcross/src/shared/flutter/build/internal/xcconfig_resolver.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/constants.dart';
import 'package:xml/xml.dart';

/// Plist / xcconfig text manipulation for the generated app bundle.
///
/// Pure string transforms (plus one filesystem probe for compiled
/// storyboards); no state, no I/O beyond that probe.
abstract final class InfoPlist {
  /// Overwrite `CFBundleIdentifier` (used when qualifying the App ID at
  /// device-sign time).
  /// Keys Xcode would inject at build time, added only when the template
  /// doesn't already declare them, in this exact order.
  ///
  /// The `UIDeviceFamily`/`DT*` group matters on iOS 26+: without it the OS
  /// refuses to register the app with SpringBoard/LaunchServices (it installs
  /// but won't launch — FBSApplicationLibrary returns nil).
  static const _requiredKeys = <RequiredPlistKey>[
    RequiredPlistKey(key: 'LSRequiresIPhoneOS', value: '<true/>'),
    RequiredPlistKey(
      key: 'UIRequiredDeviceCapabilities',
      value: '<array><string>arm64</string></array>',
    ),
    RequiredPlistKey(
      key: 'UIDeviceFamily',
      value: '<array><integer>1</integer></array>',
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
    var xml = PlistMutations.setPlistString(
      plistXml,
      'CFBundleExecutable',
      PlistDefaults.executable,
    );
    xml = PlistMutations.setBundleIdentifier(xml, bundleId);
    xml = PlistMutations.setPlistString(xml, 'CFBundlePackageType', 'APPL');
    xml = PlistMutations.setPlistString(
      xml,
      IosDeploymentConstants.minimumOsVersionKey,
      deploymentTarget.version,
    );
    for (final entry in _requiredKeys) {
      if (xml.contains(entry.key)) continue;
      xml = PlistMutations.insertBeforeEnd(
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

    final currentServices = PlistXml.valueFor(root, _bonjourServicesKey);
    if (currentServices != null && currentServices.name.local != 'array') {
      throw const FormatException('NSBonjourServices must be an array');
    }
    final currentUsage = PlistXml.valueFor(root, _localNetworkUsageKey);
    if (currentUsage != null && currentUsage.name.local != 'string') {
      throw const FormatException(
        'NSLocalNetworkUsageDescription must be a string',
      );
    }
    final hasVmService =
        currentServices != null && _containsVmService(currentServices);
    if (hasVmService && currentUsage != null) return plistXml;

    final services = currentServices ?? PlistXml.element('array');
    if (currentServices == null) {
      root.children
        ..add(PlistXml.element('key', _bonjourServicesKey))
        ..add(services);
    }
    if (!hasVmService) {
      services.children.add(PlistXml.element('string', _dartVmService));
    }
    if (currentUsage == null) {
      root.children
        ..add(PlistXml.element('key', _localNetworkUsageKey))
        ..add(PlistXml.element('string', _debugLocalNetworkUsage));
    }
    return document.toXmlString();
  }

  static const _dartVmService = '_dartVmService._tcp';
  static const _bonjourServicesKey = 'NSBonjourServices';
  static const _localNetworkUsageKey = 'NSLocalNetworkUsageDescription';
  static const _debugLocalNetworkUsage =
      'Allow Flutter tools on your computer to connect and debug '
      'your application. This prompt will not appear on release builds.';

  static bool _containsVmService(XmlElement services) =>
      services.childElements.any(
        (entry) =>
            entry.name.local == 'string' && entry.innerText == _dartVmService,
      );

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

  static String applySceneLifecycle(String xml) {
    const manifestKey = '<key>UIApplicationSceneManifest</key>';
    final manifestKeyStart = xml.indexOf(manifestKey);
    if (manifestKeyStart < 0) {
      return PlistMutations.insertBeforeEnd(xml, _sceneManifest);
    }

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
