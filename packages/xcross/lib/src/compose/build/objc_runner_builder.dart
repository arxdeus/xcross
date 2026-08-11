import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
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
    _validateMachO(runnerPath);
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
  final generic = p.join(
    toolchain.darwinSdkPath,
    'Developer',
    'Platforms',
    'iPhoneOS.platform',
    'Developer',
    'SDKs',
    'iPhoneOS.sdk',
  );
  if (Directory(generic).existsSync()) return generic;
  final sdkDir = Directory(
    p.join(
      toolchain.darwinSdkPath,
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
    ),
  );
  if (sdkDir.existsSync()) {
    final candidates =
        sdkDir
            .listSync()
            .whereType<Directory>()
            .where((dir) => p.basename(dir.path).startsWith('iPhoneOS'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    if (candidates.isNotEmpty) return candidates.last.path;
  }
  throw XcrossError('iPhoneOS SDK not found under ${toolchain.darwinSdkPath}');
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

void _validateMachO(String path) {
  final file = File(path);
  if (!file.existsSync() || file.lengthSync() < 4) {
    throw XcrossError('Runner Mach-O output is empty or missing: $path');
  }
  final bytes = file.openSync()..setPositionSync(0);
  try {
    final header = bytes.readSync(4);
    final data = ByteData.sublistView(Uint8List.fromList(header));
    final big = data.getUint32(0);
    final little = data.getUint32(0, Endian.little);
    if (big != 0xfeedfacf && little != 0xfeedfacf) {
      throw XcrossError('Runner output is not a 64-bit Mach-O: $path');
    }
  } finally {
    bytes.closeSync();
  }
}
