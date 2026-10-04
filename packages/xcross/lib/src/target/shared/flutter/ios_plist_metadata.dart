import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/artifact/plist_xml.dart';
import 'package:xcross/src/shared/flutter/constants.dart';
import 'package:xml/xml.dart';

@internal
abstract final class IosPlistMetadata {
  static Map<String, XmlElement> values(
    IosBuildPlatformInterface platform,
    String? sdkName,
  ) {
    final selectedSdk =
        sdkName ?? '${platform.sdkName}${IosDeploymentConstants.sdkVersion}';
    final version =
        RegExp(r'[0-9].*$').firstMatch(selectedSdk)?.group(0) ??
        IosDeploymentConstants.sdkVersion;
    return {
      'CFBundleSupportedPlatforms': PlistXml.element('array')
        ..children.add(PlistXml.element('string', platform.platformName)),
      'DTPlatformName': PlistXml.element('string', platform.sdkName),
      'DTSDKName': PlistXml.element('string', selectedSdk),
      'DTPlatformVersion': PlistXml.element('string', version),
    };
  }

  static String fillMissing(
    String xml, {
    required IosBuildPlatformInterface platform,
    String? sdkName,
  }) {
    final document = XmlDocument.parse(xml);
    final root = document.rootElement.getElement('dict');
    if (root == null) {
      throw const FormatException('Info.plist has no root dict');
    }
    var changed = false;
    for (final entry in values(platform, sdkName).entries) {
      if (PlistXml.valueFor(root, entry.key) != null) continue;
      root.children
        ..add(PlistXml.element('key', entry.key))
        ..add(entry.value);
      changed = true;
    }
    return changed ? document.toXmlString() : xml;
  }

  static String overwrite(
    String xml, {
    required IosBuildPlatformInterface platform,
    String? sdkName,
  }) {
    final document = XmlDocument.parse(xml);
    final root = document.rootElement.getElement('dict');
    if (root == null) {
      throw const FormatException('Info.plist has no root dict');
    }
    for (final entry in values(platform, sdkName).entries) {
      final current = PlistXml.valueFor(root, entry.key);
      if (current == null) {
        root.children
          ..add(PlistXml.element('key', entry.key))
          ..add(entry.value);
      } else {
        root.children[root.children.indexOf(current)] = entry.value;
      }
    }
    return document.toXmlString();
  }
}
