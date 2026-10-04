import 'package:meta/meta.dart';
import 'package:xml/xml.dart';

@internal
abstract final class PlistXml {
  /// The value element following `<key>[name]</key>` in [dict], or null.
  static XmlElement? valueFor(XmlElement dict, String name) {
    final entries = dict.childElements.toList();
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].name.local == 'key' &&
          entries[i].innerText.trim() == name) {
        if (i + 1 >= entries.length || entries[i + 1].name.local == 'key') {
          throw FormatException('Info.plist key $name has no value');
        }
        return entries[i + 1];
      }
    }
    return null;
  }

  static XmlElement element(String name, [String? text]) =>
      XmlElement(XmlName.parts(name), [], [if (text != null) XmlText(text)]);
}
