import 'package:meta/meta.dart';
import 'package:xcross/src/shared/artifact/plist_xml.dart';
import 'package:xml/xml.dart';

/// Writes the legacy `PkgInfo` file Xcode emits into every application
/// bundle: the 4-char `CFBundlePackageType` followed by the 4-char
/// `CFBundleSignature` (`APPL????` for a default iOS app).
@internal
abstract final class BundlePkgInfo {
  static const String fileName = 'PkgInfo';

  /// Contents derived from [infoPlistXml], padded or truncated to 4 chars
  /// per field like Xcode's ProcessInfoPlistFile.
  static String contentsFor(String infoPlistXml) {
    final root = XmlDocument.parse(infoPlistXml).rootElement.getElement('dict');
    String field(String key, String fallback) {
      final value = root == null ? null : PlistXml.valueFor(root, key);
      final text = value?.name.local == 'string' ? value!.innerText : '';
      final chosen = text.isEmpty ? fallback : text;
      return chosen.padRight(4, '?').substring(0, 4);
    }

    return field('CFBundlePackageType', 'APPL') +
        field('CFBundleSignature', '????');
  }
}
