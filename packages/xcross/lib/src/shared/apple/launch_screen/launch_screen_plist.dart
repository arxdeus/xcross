import 'package:meta/meta.dart';

/// Replaces an uncompilable `UILaunchStoryboardName` with `UILaunchScreen`.
@internal
final class LaunchScreenPlist {
  const LaunchScreenPlist._();

  static final _launchPattern = RegExp(
    r'<key>UILaunchStoryboardName(?:~\w+)?</key>\s*<string>([^<]*)</string>',
  );

  /// Mirrors `PlistStoryboardPolicy`: only the first matching key becomes
  /// `UILaunchScreen`, and only when none exists in the pre-replace [xml].
  /// [shouldReplace] decides per storyboard name (e.g. "has no compiled
  /// storyboardc"); by default every name is replaced.
  static String apply(
    String xml,
    Map<String, Object?> uiLaunchScreen, {
    bool Function(String name)? shouldReplace,
  }) {
    final hasScreen = xml.contains('UILaunchScreen');
    var inserted = false;
    return xml.replaceAllMapped(_launchPattern, (m) {
      if (!(shouldReplace?.call(m.group(1)!) ?? true)) return m.group(0)!;
      if (!hasScreen && !inserted) {
        inserted = true;
        return '<key>UILaunchScreen</key>\n\t${_dict(uiLaunchScreen)}';
      }
      return '';
    });
  }

  static String _dict(Map<String, Object?> map) {
    if (map.isEmpty) return '<dict/>';
    final b = StringBuffer('<dict>\n');
    for (final e in map.entries) {
      b.write('\t\t<key>${_esc(e.key)}</key>\n');
      final v = e.value;
      b.write(switch (v) {
        bool() => v ? '\t\t<true/>\n' : '\t\t<false/>\n',
        _ => '\t\t<string>${_esc('$v')}</string>\n',
      });
    }
    b.write('\t</dict>');
    return b.toString();
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
