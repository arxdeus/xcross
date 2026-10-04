import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_target.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/runner_binary.dart';
import 'package:xcross/src/shared/flutter/build/ios_native_assets.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/flutter_bundle_assembler.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

import '../../host_operations_fixtures.dart';
import '../flutter_test_runtime.dart';

void main() {
  test(
    'real bundle assembly preserves opposite target and selects matching engine metadata',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'xcross_bundle_assembly_',
      );
      addTearDown(() => project.deleteSync(recursive: true));
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: fixture\n');
      final app = Directory(p.join(project.path, 'App.framework'))
        ..createSync();
      File(p.join(app.path, 'App')).writeAsStringSync('kernel');
      final engine = Directory(p.join(project.path, 'Flutter.xcframework'))
        ..createSync();
      for (final identifier in ['ios-arm64', 'ios-arm64-simulator']) {
        final framework = Directory(
          p.join(engine.path, identifier, 'Flutter.framework'),
        )..createSync(recursive: true);
        File(p.join(framework.path, 'Flutter')).writeAsStringSync(identifier);
      }
      final runner = File(p.join(project.path, 'Runner'))
        ..writeAsStringSync('runner');
      final library = File(p.join(project.path, 'libPlugin.dylib'))
        ..writeAsStringSync('plugin');
      final native = Directory(p.join(project.path, 'Native.framework'))
        ..createSync();
      File(p.join(native.path, 'Native')).writeAsStringSync('native');
      final physical = testIPhoneRuntime();
      final simulator = testSimulatorRuntime();

      Future<String> assemble(FlutterBuildRuntime<LinuxHost> runtime) {
        final request = FlutterBuildRequest(
          runtime: runtime,
          projectRoot: project.path,
          bundleId: 'com.example.fixture',
          options: const FlutterBuildOptions(
            pub: false,
            buildName: '2.3',
            buildNumber: '45',
          ),
        );
        final context = FlutterBuildContext(
          request: request,
          flutterRoot: '/unused',
        );
        return FlutterBundleAssembler(context).assemble(
          FlutterLinkedArtifacts(
            compiled: FlutterCompiledArtifacts(
              appFramework: app.path,
              nativeAssets: IosNativeAssetsBuildResult(
                manifestPath: '/unused',
                frameworks: [native.path],
              ),
            ),
            runner: RunnerBinary(
              xcframework: engine.path,
              runnerBinary: runner.path,
              sdkName: runtime.target.buildPlatform.sdkName,
            ),
            extensions: const [],
          ),
        );
      }

      final physicalBundle = await assemble(physical);
      final preserved = File(p.join(physicalBundle, 'device-sentinel'))
        ..writeAsStringSync('untouched');
      final simulatorBundle = await assemble(simulator);
      expect(physicalBundle, isNot(simulatorBundle));
      expect(preserved.readAsStringSync(), 'untouched');
      expect(
        File(
          p.join(physicalBundle, 'Frameworks', 'Flutter.framework', 'Flutter'),
        ).readAsStringSync(),
        'ios-arm64',
      );
      expect(
        File(
          p.join(simulatorBundle, 'Frameworks', 'Flutter.framework', 'Flutter'),
        ).readAsStringSync(),
        'ios-arm64-simulator',
      );
      expect(
        File(
          p.join(simulatorBundle, 'Frameworks', 'App.framework', 'App'),
        ).readAsStringSync(),
        'kernel',
      );
      expect(
        File(
          p.join(simulatorBundle, 'Frameworks', 'Native.framework', 'Native'),
        ).readAsStringSync(),
        'native',
      );
      final devicePlist = File(
        p.join(physicalBundle, 'Info.plist'),
      ).readAsStringSync();
      final simPlist = File(
        p.join(simulatorBundle, 'Info.plist'),
      ).readAsStringSync();
      expect(devicePlist, contains('<string>iPhoneOS</string>'));
      expect(simPlist, contains('<string>iPhoneSimulator</string>'));
      expect(simPlist, contains('<string>com.example.fixture</string>'));
      expect(simPlist, contains('<string>2.3</string>'));
      expect(simPlist, contains('<string>45</string>'));
      final frameworks = Directory(p.join(simulatorBundle, 'Frameworks'));
      await simulator.frameworks.copyPluginLibraries([
        library.path,
      ], frameworks.path);
      expect(
        File(p.join(frameworks.path, 'libPlugin.dylib')).readAsStringSync(),
        'plugin',
      );
    },
  );
  test(
    'mapped bundle assembly preserves destination mapping and target isolation',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'mapped-bundle-assembly-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final fileSystem = FixtureMappedFileSystem(root);
      final host = LinuxHost(
        fileSystem: fileSystem,
        currentDirectory: '/selected-project',
        temporaryDirectory: '/selected-temp',
      );
      fileSystem.directory('/selected-temp').createSync();
      fileSystem.file('/selected-project/pubspec.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('name: mapped_fixture\n');
      for (final (path, contents) in [
        ('/selected-input/App.framework/App', 'kernel'),
        ('/selected-input/Runner', 'runner'),
        ('/selected-input/Native.framework/Native', 'native'),
        ('/selected-input/libPlugin.dylib', 'plugin'),
        (
          '/selected-input/Flutter.xcframework/ios-arm64/Flutter.framework/Flutter',
          'device',
        ),
        (
          '/selected-input/Flutter.xcframework/ios-arm64-simulator/Flutter.framework/Flutter',
          'simulator',
        ),
      ]) {
        fileSystem.file(path)
          ..createSync(recursive: true)
          ..writeAsStringSync(contents);
      }
      final physical = testFlutterRuntime(
        IPhoneFlutterTarget(IPhoneTarget(host)),
      );
      final simulator = testFlutterRuntime(
        SimulatorFlutterTarget(SimulatorTarget(host)),
      );
      Future<String> assemble(FlutterBuildRuntime<LinuxHost> runtime) =>
          FlutterBundleAssembler(
            FlutterBuildContext(
              request: FlutterBuildRequest(
                runtime: runtime,
                projectRoot: '/selected-project',
                bundleId: 'com.example.mapped',
                options: const FlutterBuildOptions(pub: false),
              ),
              flutterRoot: '/unused',
            ),
          ).assemble(
            FlutterLinkedArtifacts(
              compiled: const FlutterCompiledArtifacts(
                appFramework: '/selected-input/App.framework',
                nativeAssets: IosNativeAssetsBuildResult(
                  manifestPath: '/unused',
                  frameworks: ['/selected-input/Native.framework'],
                ),
              ),
              runner: RunnerBinary(
                xcframework: '/selected-input/Flutter.xcframework',
                runnerBinary: '/selected-input/Runner',
                sdkName: runtime.target.buildPlatform.sdkName,
              ),
              extensions: const [],
            ),
          );
      final physicalBundle = await assemble(physical);
      fileSystem
          .file('$physicalBundle/device-sentinel')
          .writeAsStringSync('untouched');
      final simulatorBundle = await assemble(simulator);
      expect(physicalBundle, isNot(simulatorBundle));
      expect(
        fileSystem.file('$physicalBundle/device-sentinel').readAsStringSync(),
        'untouched',
      );
      expect(
        fileSystem
            .file('$physicalBundle/Frameworks/Flutter.framework/Flutter')
            .readAsStringSync(),
        'device',
      );
      expect(
        fileSystem
            .file('$simulatorBundle/Frameworks/Flutter.framework/Flutter')
            .readAsStringSync(),
        'simulator',
      );
      expect(
        fileSystem
            .file('$simulatorBundle/Frameworks/App.framework/App')
            .readAsStringSync(),
        'kernel',
      );
      expect(
        fileSystem
            .file('$simulatorBundle/Frameworks/Native.framework/Native')
            .readAsStringSync(),
        'native',
      );
      expect(
        fileSystem.file('$simulatorBundle/Runner').readAsStringSync(),
        'runner',
      );
      await simulator.frameworks.copyPluginLibraries([
        '/selected-input/libPlugin.dylib',
      ], '$simulatorBundle/Frameworks');
      expect(
        fileSystem
            .file('$simulatorBundle/Frameworks/libPlugin.dylib')
            .readAsStringSync(),
        'plugin',
      );
      expect(fileSystem.touched, contains('$simulatorBundle/Runner'));
      expect(
        fileSystem.touched,
        contains('$simulatorBundle/Frameworks/libPlugin.dylib'),
      );
      expect(fileSystem.directory('/selected-temp').listSync(), isEmpty);
      expect(File('$simulatorBundle/Runner').existsSync(), isFalse);
    },
  );
}
