import 'dart:io';
import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/mach_o_validator.dart';
import 'package:xcross/src/compose/build/process_invocation.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/errors.dart';

typedef ComposeRunChecked =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

const _iosMinimumVersion = '15.0';
const _iosTargetTriple = 'arm64-apple-ios15.0';

final class ObjcRunnerBuilder {
  ObjcRunnerBuilder() : _runChecked = _defaultRunChecked;

  const ObjcRunnerBuilder.withSeams({required ComposeRunChecked runChecked})
    : _runChecked = runChecked;

  final ComposeRunChecked _runChecked;

  Future<String> build({
    required KmpProject project,
    required String frameworkPath,
    required ComposeToolchain toolchain,
  }) async {
    _validateFramework(project, frameworkPath);
    final iphoneSdk = _iphoneSdk(toolchain);
    final frameworkParent = p.dirname(frameworkPath);
    final buildDir = p.join(project.root, 'iosApp', '.build', 'runner');
    final runnerBuildDir = Directory(buildDir);
    if (runnerBuildDir.existsSync()) {
      await runnerBuildDir.delete(recursive: true);
    }
    await runnerBuildDir.create(recursive: true);

    final generatedDir = p.join(
      project.root,
      'build',
      'xcross-compose',
      'Runner',
    );
    await Directory(generatedDir).create(recursive: true);
    final sourcePath = p.join(generatedDir, 'main.m');
    await File(sourcePath).writeAsString(_source(project));

    final objectPath = p.join(buildDir, 'main.o');
    final clang = ProcessInvocation.forHost(toolchain.host, toolchain.clang, [
      '-target',
      _iosTargetTriple,
      '-isysroot',
      iphoneSdk,
      '-F',
      p.join(iphoneSdk, 'System', 'Library', 'Frameworks'),
      '-F',
      p.join(iphoneSdk, 'System', 'Library', 'SubFrameworks'),
      '-F',
      frameworkParent,
      '-I',
      p.join(frameworkPath, 'Headers'),
      '-fobjc-arc',
      '-miphoneos-version-min=$_iosMinimumVersion',
      '-c',
      sourcePath,
      '-o',
      objectPath,
    ]);
    await _runChecked(
      clang.executable,
      clang.arguments,
      workingDirectory: project.root,
    );
    if (!File(objectPath).existsSync()) {
      throw XcrossError('ObjC runner object was not produced: $objectPath');
    }

    final runnerPath = p.join(buildDir, 'Runner');
    final ld = ProcessInvocation.forHost(toolchain.host, toolchain.ld64Lld, [
      '-arch',
      'arm64',
      '-platform_version',
      'ios',
      _iosMinimumVersion,
      _sdkVersion(iphoneSdk) ?? '26.5',
      '-syslibroot',
      iphoneSdk,
      '-o',
      runnerPath,
      objectPath,
      '-F',
      frameworkParent,
      '-F',
      p.join(iphoneSdk, 'System', 'Library', 'Frameworks'),
      '-F',
      p.join(iphoneSdk, 'System', 'Library', 'SubFrameworks'),
      '-framework',
      project.baseName,
      '-framework',
      'UIKit',
      '-framework',
      'Foundation',
      '-lobjc',
      '-lc',
      '-rpath',
      '@executable_path/Frameworks',
    ]);
    await _runChecked(
      ld.executable,
      ld.arguments,
      workingDirectory: project.root,
    );
    MachOValidator.validate64BitExecutable(runnerPath);
    if (!Platform.isWindows) ProcessRunner.makeExecutable(runnerPath);
    return runnerPath;
  }

  static Future<void> _defaultRunChecked(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => ProcessRunner.runChecked(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    label: p.basename(executable),
  );

  static String _source(KmpProject project) {
    final objcClass =
        '${project.baseName}${project.entryClass ?? 'MainViewControllerKt'}';
    final selector = project.entrySelector ?? 'MainViewController';
    return '#import <UIKit/UIKit.h>\n'
        '#import <${project.baseName}/${project.baseName}.h>\n'
        '@interface AppDelegate : UIResponder <UIApplicationDelegate>\n'
        '@property (strong, nonatomic) UIWindow *window;\n'
        '@end\n'
        '@implementation AppDelegate\n'
        '- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {\n'
        '    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];\n'
        // Compose only paints the pixels its content draws: a composable
        // tree without a Surface/Box background leaves the Skiko layer
        // transparent, and an uncoloured UIWindow shows through as pure
        // black, which reads as "the app launched to a black screen".
        '    self.window.backgroundColor = [UIColor systemBackgroundColor];\n'
        '    self.window.rootViewController = [$objcClass $selector];\n'
        '    [self.window makeKeyAndVisible];\n'
        '    return YES;\n'
        '}\n'
        '@end\n'
        'int main(int argc, char *argv[]) {\n'
        '    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }\n'
        '}\n';
  }
}

String _iphoneSdk(ComposeToolchain toolchain) {
  // ComposeToolchainResolver already resolves darwinSdkPath down to the
  // specific "iPhoneOS(.\d+)?.sdk" leaf (DarwinSdk.iPhoneOSSdk()), so use it
  // directly. Previously this re-derived a path by joining darwinSdkPath
  // with "Developer/Platforms/iPhoneOS.platform/..." again, which only
  // worked by coincidence in tests that pointed darwinSdkPath at a bundle
  // root; against a real resolved toolchain darwinSdkPath is already the
  // leaf SDK, so that join produced a nonexistent nested path.
  if (Directory(toolchain.darwinSdkPath).existsSync()) {
    return toolchain.darwinSdkPath;
  }
  throw XcrossError('iPhoneOS SDK not found at ${toolchain.darwinSdkPath}');
}

String? _sdkVersion(String sdkPath) {
  final name = p.basenameWithoutExtension(sdkPath);
  if (!name.startsWith('iPhoneOS')) return null;
  final version = name.substring('iPhoneOS'.length);
  return version.isEmpty ? null : version;
}

void _validateFramework(KmpProject project, String frameworkPath) {
  if (!Directory(frameworkPath).existsSync()) {
    throw XcrossError('Compose framework not found: $frameworkPath');
  }
  if (!File(p.join(frameworkPath, project.baseName)).existsSync()) {
    throw XcrossError(
      'Compose framework binary not found: ${p.join(frameworkPath, project.baseName)}',
    );
  }
}
