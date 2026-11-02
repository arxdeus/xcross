import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/artifact/plist_xml.dart';
import 'package:xml/xml.dart';

/// Toolchain provenance keys Xcode stamps into every built Info.plist
/// (`DTXcode`, `DTXcodeBuild`, `DTSDKBuild`, `DTPlatformBuild`,
/// `DTCompiler`). App Store Connect validates them against the minimum
/// Xcode/SDK it accepts, so they are read from the installed SDK and never
/// invented: a key whose source is unavailable is omitted.
@internal
final class XcodeBuildMetadata {
  const XcodeBuildMetadata({this.sdkBuild, this.xcodeVersion, this.xcodeBuild});

  /// Parses `<sdk>/System/Library/CoreServices/SystemVersion.plist` and
  /// `Xcode.app/Contents/version.plist` sources (either may be null).
  factory XcodeBuildMetadata.fromPlists({
    String? sdkSystemVersion,
    String? xcodeVersionPlist,
  }) => XcodeBuildMetadata(
    sdkBuild: _string(sdkSystemVersion, 'ProductBuildVersion'),
    xcodeVersion: _xcodeVersionCode(
      _string(xcodeVersionPlist, 'CFBundleShortVersionString'),
    ),
    xcodeBuild: _string(xcodeVersionPlist, 'ProductBuildVersion'),
  );

  /// Reads the metadata of the platform SDK at [sdkPath]; files that are
  /// missing or unreadable leave their keys out.
  factory XcodeBuildMetadata.load(
    HostFileSystemInterface fileSystem,
    p.Context paths,
    String sdkPath,
  ) {
    String? read(String path) {
      final file = fileSystem.file(path);
      try {
        return file.existsSync() ? file.readAsStringSync() : null;
      } on Exception {
        return null;
      }
    }

    return XcodeBuildMetadata.fromPlists(
      sdkSystemVersion: read(systemVersionPath(paths, sdkPath)),
      xcodeVersionPlist: read(xcodeVersionPath(paths, sdkPath)),
    );
  }

  /// Xcode's `$(GCC_VERSION)` for every clang-built target.
  static const String compiler = 'com.apple.compilers.llvm.clang.1_0';

  final String? sdkBuild;

  /// `XCODE_VERSION_ACTUAL`, e.g. `2660` for Xcode 26.6.
  final String? xcodeVersion;
  final String? xcodeBuild;

  /// `SystemVersion.plist` inside a platform SDK directory.
  static String systemVersionPath(p.Context paths, String sdkPath) =>
      paths.join(
        sdkPath,
        'System',
        'Library',
        'CoreServices',
        'SystemVersion.plist',
      );

  /// `Contents/version.plist` of the Xcode the SDK was extracted from:
  /// `<Contents>/Developer/Platforms/<P>.platform/Developer/SDKs/<S>.sdk`
  /// (an installed xcross SDK mirrors that layout under its root).
  static String xcodeVersionPath(p.Context paths, String sdkPath) {
    var contents = sdkPath;
    for (var i = 0; i < 6; i++) {
      contents = paths.dirname(contents);
    }
    return paths.join(contents, 'version.plist');
  }

  Map<String, XmlElement> values() => {
    if (xcodeVersion != null || sdkBuild != null)
      'DTCompiler': PlistXml.element('string', compiler),
    if (sdkBuild != null) ...{
      'DTPlatformBuild': PlistXml.element('string', sdkBuild),
      'DTSDKBuild': PlistXml.element('string', sdkBuild),
    },
    if (xcodeVersion != null)
      'DTXcode': PlistXml.element('string', xcodeVersion),
    if (xcodeBuild != null)
      'DTXcodeBuild': PlistXml.element('string', xcodeBuild),
  };

  static String? _string(String? xml, String key) {
    if (xml == null) return null;
    try {
      final root = XmlDocument.parse(xml).rootElement.getElement('dict');
      final value = root == null ? null : PlistXml.valueFor(root, key);
      if (value == null || value.name.local != 'string') return null;
      final text = value.innerText.trim();
      return text.isEmpty ? null : text;
    } on XmlException {
      return null;
    }
  }

  static String? _xcodeVersionCode(String? version) {
    if (version == null) return null;
    final match = RegExp(r'^(\d+)(?:\.(\d))?(?:\.(\d))?$').firstMatch(version);
    if (match == null) return null;
    final major = match.group(1)!.padLeft(2, '0');
    return '$major${match.group(2) ?? '0'}${match.group(3) ?? '0'}';
  }
}
