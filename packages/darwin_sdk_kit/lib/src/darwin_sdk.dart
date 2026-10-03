import 'dart:convert';
import 'dart:io';
import 'package:darwin_sdk_kit/src/errors.dart';
import 'package:darwin_sdk_kit/src/target/iphone/iphone_build_platform.dart';
import 'package:darwin_sdk_kit/src/target/shared/ios_build_platform.dart';
import 'package:darwin_sdk_kit/src/target/simulator/simulator_build_platform.dart';
import 'package:path/path.dart' as p;

final class DarwinSdk {
  const DarwinSdk(this.bundle);
  final String bundle;
  String get swiftSdkPath => bundle;
  static final RegExp _digitPattern = RegExp('[0-9]');

  /// A complete bundle has Swift artifact metadata and a usable iPhoneOS SDK.
  static bool isValidBundle(String candidate) {
    const metadata = ['info.json', 'swift-sdk.json', 'toolset.json'];
    if (!metadata.every((n) => File(p.join(candidate, n)).existsSync())) {
      return false;
    }

    try {
      final sdk = _firstSdk(_sdksDir(candidate, 'iPhoneOS'), 'iPhoneOS');
      if (sdk == null) return false;

      final canonicalLayout = _canonicalLayout(candidate);
      final swiftResources = canonicalLayout.parent;
      if (!Directory(
            p.join(sdk, 'System', 'Library', 'Frameworks'),
          ).existsSync() ||
          !swiftResources.existsSync() ||
          !_hasContent(canonicalLayout) ||
          !_hasContent(_runtimeLayout(candidate))) {
        return false;
      }

      final simulatorPlatform = p.join(
        candidate,
        'Developer',
        'Platforms',
        'iPhoneSimulator.platform',
      );
      if (FileSystemEntity.typeSync(simulatorPlatform, followLinks: false) !=
              FileSystemEntityType.notFound &&
          !isValidSimulatorSlice(candidate)) {
        return false;
      }
      final metadata = jsonDecode(
        File(p.join(candidate, 'swift-sdk.json')).readAsStringSync(),
      );
      final targets = metadata is Map ? metadata['targetTriples'] : null;
      if (targets is Map) {
        for (final target in targets.entries) {
          final triple = target.key;
          if (triple is! String ||
              !triple.contains('-apple-ios') ||
              !triple.endsWith('-simulator')) {
            continue;
          }
          if (!isValidSimulatorSlice(candidate)) return false;
          final properties = target.value;
          if (properties is Map &&
              !isValidSimulatorSlice(
                candidate,
                sdkRootPath: properties['sdkRootPath'] is String
                    ? properties['sdkRootPath'] as String
                    : null,
                swiftResourcesPath: properties['swiftResourcesPath'] is String
                    ? properties['swiftResourcesPath'] as String
                    : null,
              )) {
            return false;
          }
        }
      }
      return true;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  static bool isValidSimulatorSlice(
    String candidate, {
    String? sdkRootPath,
    String? swiftResourcesPath,
  }) {
    try {
      final sdk = sdkRootPath == null
          ? _firstSdk(_sdksDir(candidate, 'iPhoneSimulator'), 'iPhoneSimulator')
          : p.join(candidate, sdkRootPath);
      if (sdk == null) return false;
      final resources = swiftResourcesPath == null
          ? _canonicalLayout(candidate).parent.parent.path
          : p.join(candidate, swiftResourcesPath);
      return _hasEntries(
            Directory(p.join(sdk, 'System', 'Library', 'Frameworks')),
          ) &&
          _hasEntries(Directory(p.join(resources, 'iphonesimulator')));
    } on FileSystemException {
      return false;
    }
  }

  static bool _hasEntries(Directory directory) =>
      directory.existsSync() && directory.listSync().isNotEmpty;

  static bool _hasContent(File file) =>
      file.existsSync() && file.lengthSync() > 0;

  /// First versioned iPhoneOSXX.X.sdk found, else first iPhoneOS.sdk.
  String iPhoneOSSdk() => iosSdk();

  String iPhoneSimulatorSdk() => iosSdk(target: const SimulatorBuildPlatform());

  String iosSdk({
    IosBuildPlatformInterface target = const IPhoneBuildPlatform(),
  }) {
    final platform = target.platformName;
    final dir = _sdksDir(bundle, platform);
    final pick = _firstSdk(dir, platform);
    if (pick == null) {
      throw DarwinSdkError(
        'DarwinSdk: Could not find an $platform SDK under $dir.\n'
        'Install one with `xcross sdk install <Xcode.xip|Xcode.app>`.',
      );
    }
    return pick;
  }

  static String _sdksDir(String bundle, String platform) => p.join(
    bundle,
    'Developer',
    'Platforms',
    '$platform.platform',
    'Developer',
    'SDKs',
  );

  static File _canonicalLayout(String bundle) => File(
    p.join(
      bundle,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
      'iphoneos',
      'layouts-arm64.yaml',
    ),
  );

  static File _runtimeLayout(String bundle) => File(
    p.join(
      bundle,
      'Developer',
      'Runtimes',
      'XcodeDefault.xctoolchain',
      'usr',
      'bin',
      'layouts-arm64.yaml',
    ),
  );

  static String? _firstSdk(String dir, String prefix) {
    final directory = Directory(dir);
    if (!directory.existsSync()) return null;
    final names =
        directory
            .listSync()
            .where(
              (entry) =>
                  entry is Directory ||
                  FileSystemEntity.typeSync(entry.path) ==
                      FileSystemEntityType.directory,
            )
            .map((entry) => p.basename(entry.path))
            .where((name) => name.startsWith(prefix) && name.endsWith('.sdk'))
            .toList()
          ..sort();

    final pick =
        names.where((name) => name.contains(_digitPattern)).firstOrNull ??
        names.firstOrNull;
    return pick == null ? null : p.join(dir, pick);
  }
}
