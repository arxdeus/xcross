import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/constants.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/xtool/darwin_sdk.dart';

/// Embeds the ObjC Runner.m source, compiles it with clang, and links it with
/// ld64.lld to produce the `Runner` executable for an iOS `.app` bundle.
///
/// This is the cross-platform (Linux) equivalent of the Xcode-built Runner.
class RunnerShim {
  /// Compile and link the Runner binary.
  ///
  /// [projectRoot]        — Flutter project root (used for output staging).
  /// [sdk]                — Resolved [DarwinSdk] (provides sysroot + ld64.lld).
  /// [flutterXcframework] — Path to `Flutter.xcframework`.
  /// [outputDir]          — Directory where `Runner` binary is written.
  /// [pluginsLibrary]     — Absolute path to the aggregate Flutter-plugins
  ///                        dylib (from `GeneratedPluginsPackage.build`), or
  ///                        null when the project has no Swift Package
  ///                        Manager plugins. When non-null, Runner.m calls
  ///                        into it for plugin registration instead of using
  ///                        an empty local stub, and it's linked directly
  ///                        into the Runner binary.
  ///
  /// Returns path to the linked `Runner` executable.
  static Future<String> buildRunnerBinary({
    required String projectRoot,
    required DarwinSdk sdk,
    required String flutterXcframework,
    required String outputDir,
    String? pluginsLibrary,
  }) => Log.logStep('Compiling Runner', () async {
    final clang = await ProcessRunner.locateTool(
      Platform.isWindows ? 'clang.exe' : 'clang',
    );
    final iosSdk = _resolveIPhoneOsSDK(sdk);
    final flutterSlice = _flutterDeviceSlice(flutterXcframework);
    final subframeworks = p.join(iosSdk, 'System', 'Library', 'SubFrameworks');

    await Directory(outputDir).create(recursive: true);
    final sourcePath = p.join(outputDir, 'Runner.m');
    final objectPath = p.join(outputDir, 'Runner.o');
    final outputPath = p.join(outputDir, 'Runner');

    await File(
      sourcePath,
    ).writeAsString(_runnerObjcSource(hasPlugins: pluginsLibrary != null));

    await _compileObject(
      clang: clang,
      sourcePath: sourcePath,
      objectPath: objectPath,
      iosSdk: iosSdk,
      subframeworks: subframeworks,
      flutterSlice: flutterSlice,
    );

    // _sdkVersion() returns null whenever the un-versioned iPhoneOS.sdk
    // symlink is used (the standard install), so this fallback is what
    // reaches ld64.lld's -platform_version and lands in LC_BUILD_VERSION.
    final sdkVersion = _sdkVersion(iosSdk) ?? '26.5';
    await _linkBinary(
      ld64lld: await resolveLd64Lld(sdk),
      objectPath: objectPath,
      outputPath: outputPath,
      iosSdk: iosSdk,
      flutterSlice: flutterSlice,
      subframeworks: subframeworks,
      sdkVersion: sdkVersion,
      pluginsLibrary: pluginsLibrary,
    );

    final outputPathExists = File(outputPath).existsSync();
    if (!outputPathExists) {
      throw XcrossError(
        'RunnerShim: clang/ld64.lld did not produce '
        'Runner at $outputPath',
      );
    }

    ProcessRunner.makeExecutable(outputPath);
    final size = await File(outputPath).length();
    Log.logTrace('Runner binary produced: $outputPath (${size ~/ 1024} KB)');

    return outputPath;
  });

  /// Compile [sourcePath] to [objectPath] via clang.
  static Future<void> _compileObject({
    required String clang,
    required String sourcePath,
    required String objectPath,
    required String iosSdk,
    required String subframeworks,
    required String flutterSlice,
  }) async {
    Log.logTrace('[clang] compile Runner.m → Runner.o');
    await ProcessRunner.runChecked(
      clang,
      [
        '-target',
        IosDeploymentConstants.buildTriple,
        '-isysroot',
        iosSdk,
        '-F',
        subframeworks,
        '-F',
        flutterSlice,
        '-I',
        p.join(flutterSlice, 'Flutter.framework', 'Headers'),
        '-fobjc-arc',
        '-miphoneos-version-min=${IosDeploymentConstants.minDeploymentTarget}',
        '-c',
        sourcePath,
        '-o',
        objectPath,
      ],
      inheritStdio: Log.isVerbose,
      label: 'clang',
    );
  }

  /// Link [objectPath] to [outputPath] via ld64.lld. When [pluginsLibrary] is
  /// given, it's passed straight to the linker as an extra input file — its
  /// absolute path resolves the symbols directly, regardless of where it's
  /// later embedded for runtime (see [buildRunnerBinary] for the on-device
  /// loading story, handled via the existing `-rpath` below).
  static Future<void> _linkBinary({
    required String ld64lld,
    required String objectPath,
    required String outputPath,
    required String iosSdk,
    required String flutterSlice,
    required String subframeworks,
    required String sdkVersion,
    String? pluginsLibrary,
  }) async {
    Log.logTrace('[ld64.lld] link Runner.o → Runner');
    await ProcessRunner.runChecked(
      ld64lld,
      [
        '-arch',
        'arm64',
        '-platform_version',
        'ios',
        IosDeploymentConstants.minDeploymentTarget,
        sdkVersion,
        '-syslibroot',
        iosSdk,
        '-o',
        outputPath,
        objectPath,
        if (pluginsLibrary != null) pluginsLibrary,
        '-F',
        flutterSlice,
        '-F',
        p.join(iosSdk, 'System', 'Library', 'Frameworks'),
        '-F',
        subframeworks,
        '-framework',
        'Flutter',
        '-framework',
        'UIKit',
        '-framework',
        'Foundation',
        '-lobjc',
        '-lc',
        '-rpath',
        '@executable_path/Frameworks',
      ],
      inheritStdio: Log.isVerbose,
      label: 'ld64.lld',
    );
  }

  /// Prefer the generic `iPhoneOS.sdk` symlink; fall back to the versioned SDK.
  static String _resolveIPhoneOsSDK(DarwinSdk sdk) {
    final generic = p.join(
      sdk.bundle,
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
      'iPhoneOS.sdk',
    );
    if (Directory(generic).existsSync()) return generic;
    return sdk.iPhoneOSSdk();
  }

  /// Returns the `ios-arm64` slice directory inside [xcframework].
  static String _flutterDeviceSlice(String xcframework) {
    final slice = p.join(xcframework, 'ios-arm64');
    final framework = p.join(slice, 'Flutter.framework');
    final frameworkExists = Directory(framework).existsSync();
    if (!frameworkExists) {
      throw XcrossError(
        'RunnerShim: Flutter device slice not found at $framework',
      );
    }
    return slice;
  }

  /// Extract version number from SDK dir name, e.g. `iPhoneOS17.5.sdk` → `17.5`.
  static String? _sdkVersion(String sdkPath) {
    final name = p.basenameWithoutExtension(sdkPath);
    if (!name.startsWith('iPhoneOS')) return null;
    final version = name.substring('iPhoneOS'.length);
    return version.isEmpty ? null : version;
  }

  /// Minimal ObjC Runner that boots Flutter via FlutterAppDelegate.
  ///
  /// When [hasPlugins] is false (the common, today's-behaviour case), this is
  /// byte-identical to the original hardcoded template: a local, empty
  /// `GeneratedPluginRegistrant` stub, so projects without Swift Package
  /// Manager plugins are entirely unaffected.
  ///
  /// When [hasPlugins] is true, the local stub is replaced by a plain
  /// `extern` forward declaration of the `@_cdecl`-exported registrant
  /// symbol from the generated Flutter-plugins dylib (see
  /// `GeneratedPluginsPackage` in ios_plugin_package.dart) — no
  /// generated-header or clang-modules setup needed, just a normal C symbol
  /// resolved at link time by [_linkBinary].
  static String _runnerObjcSource({required bool hasPlugins}) =>
      '''
#import <UIKit/UIKit.h>
#import <Flutter/Flutter.h>

${hasPlugins ? _pluginsExternDeclaration : _emptyPluginRegistrantStub}
@interface AppDelegate : FlutterAppDelegate <FlutterImplicitEngineDelegate>
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  FlutterViewController* flutterViewController = [[FlutterViewController alloc] initWithProject:nil nibName:nil bundle:nil];
  UIWindow* window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  window.rootViewController = flutterViewController;
  [window makeKeyAndVisible];
  self.window = window;
  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}
- (void)didInitializeImplicitFlutterEngine:(NSObject<FlutterImplicitEngineBridge>*)engineBridge {
  ${hasPlugins ? '${GeneratedPluginsConstants.registrantSymbol}(engineBridge.pluginRegistry);' : '[GeneratedPluginRegistrant registerWithRegistry:engineBridge.pluginRegistry];'}
}
@end

@interface SceneDelegate : FlutterSceneDelegate
@end
@implementation SceneDelegate
@end

int main(int argc, char * argv[]) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AppDelegate"); }
}
''';

  /// Empty registrant stub — today's behaviour, used when there are no Swift
  /// Package Manager plugins to register.
  static const _emptyPluginRegistrantStub = '''
@interface GeneratedPluginRegistrant : NSObject
+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry;
@end
@implementation GeneratedPluginRegistrant
+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {}
@end
''';

  /// Forward declaration of the generated Swift registrant's `@_cdecl`
  /// symbol — plain C linkage, so no header import or `-fmodules` is needed.
  static const _pluginsExternDeclaration =
      'extern void ${GeneratedPluginsConstants.registrantSymbol}'
      '(NSObject<FlutterPluginRegistry>* registry);\n';
}
