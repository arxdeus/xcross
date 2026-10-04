import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/tbd/tbd_linker_diagnostic.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/build/mach_o_validator.dart';
import 'package:xcross/src/shared/compose/build/process_invocation.dart';
import 'package:xcross/src/shared/compose/build/swift_runner_builder.dart';
import 'package:xcross/src/shared/compose/compose_ios_constants.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/shared/errors/errors.dart';

@internal
typedef ComposeRunChecked =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

const _iosMinimumVersion = composeMinimumIosVersion;

@internal
final class ObjcRunnerBuilder<T extends PlatformHostInterface> {
  ObjcRunnerBuilder(this.runner) : _runChecked = runner.runTool;

  const ObjcRunnerBuilder.withSeams(
    this.runner, {
    required ComposeRunChecked runChecked,
  }) : _runChecked = runChecked;

  final ProcessRunner<T> runner;
  final ComposeRunChecked _runChecked;

  Future<String> build({
    required KmpProject project,
    required String frameworkPath,
    required ComposeToolchain<T> toolchain,
  }) async {
    _validateFramework(project, frameworkPath, runner.host.fileSystem);
    final iphoneSdk = _iphoneSdk(toolchain);
    final frameworkParent = p.dirname(frameworkPath);
    final buildDir = toolchain.target.runnerDirectory(project.root, 'objc');
    final runnerBuildDir = runner.host.fileSystem.directory(buildDir);
    if (runnerBuildDir.existsSync()) {
      await runnerBuildDir.delete(recursive: true);
    }
    await runnerBuildDir.create(recursive: true);

    final generatedDir = toolchain.target.generatedRunnerDirectory(
      project.root,
    );
    await runner.host.fileSystem
        .directory(generatedDir)
        .create(recursive: true);
    final sourcePath = p.join(generatedDir, 'main.m');
    await runner.host.fileSystem
        .file(sourcePath)
        .writeAsString(_source(project));

    final objectPath = p.join(buildDir, 'main.o');
    final clang = ProcessInvocation.forHost(toolchain.host, toolchain.clang, [
      '-target',
      toolchain.target.targetTriple,
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
      toolchain.target.buildPlatform.minimumVersionFlag(_iosMinimumVersion),
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
    if (!runner.host.fileSystem.file(objectPath).existsSync()) {
      throw XcrossError('ObjC runner object was not produced: $objectPath');
    }

    final runnerPath = p.join(buildDir, 'Runner');
    final ld = ProcessInvocation.forHost(toolchain.host, toolchain.ld64Lld, [
      '-arch',
      'arm64',
      '-platform_version',
      toolchain.target.linkerPlatform,
      _iosMinimumVersion,
      toolchain.target.sdkVersion(iphoneSdk) ?? composeDefaultSdkVersion,
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
      // Apple clang's driver links compiler-rt implicitly; ld64.lld does not.
      // Skia in Compose calls `__isPlatformVersionAtLeast` from it.
      if (compilerRtIos(
            toolchain.darwinSdkBundle,
            libraryName: toolchain.target.compilerRtName,
            files: runner.host.fileSystem,
          )
          case final String rt)
        rt,
      '-rpath',
      '@executable_path/Frameworks',
    ]);
    // An SDK whose text stubs still declare an architecture this linker
    // cannot parse fails here naming a framework, not the cause.
    await TbdLinkerDiagnostic.explainFailures(
      bundle: toolchain.darwinSdkBundle,
      wrap: XcrossError.new,
      () => _runChecked(
        ld.executable,
        ld.arguments,
        workingDirectory: project.root,
      ),
    );
    MachOValidator(runner.host.fileSystem).validate64BitExecutable(runnerPath);
    runner.makeExecutable(runnerPath);
    return runnerPath;
  }

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

String _iphoneSdk<T extends PlatformHostInterface>(
  ComposeToolchain<T> toolchain,
) {
  // ComposeToolchainResolver already resolves darwinSdkPath down to the
  // specific "iPhoneOS(.\d+)?.sdk" leaf (DarwinSdk.iPhoneOSSdk()), so use it
  // directly. Previously this re-derived a path by joining darwinSdkPath
  // with "Developer/Platforms/iPhoneOS.platform/..." again, which only
  // worked by coincidence in tests that pointed darwinSdkPath at a bundle
  // root; against a real resolved toolchain darwinSdkPath is already the
  // leaf SDK, so that join produced a nonexistent nested path.
  if (toolchain.target.host.fileSystem
      .directory(toolchain.darwinSdkPath)
      .existsSync()) {
    return toolchain.darwinSdkPath;
  }
  throw XcrossError(
    '${toolchain.target.buildPlatform.sdkName} SDK not found at ${toolchain.darwinSdkPath}',
  );
}

void _validateFramework(
  KmpProject project,
  String frameworkPath,
  HostFileSystemInterface files,
) {
  if (!files.directory(frameworkPath).existsSync()) {
    throw XcrossError('Compose framework not found: $frameworkPath');
  }
  if (!files.file(p.join(frameworkPath, project.baseName)).existsSync()) {
    throw XcrossError(
      'Compose framework binary not found: ${p.join(frameworkPath, project.baseName)}',
    );
  }
}
