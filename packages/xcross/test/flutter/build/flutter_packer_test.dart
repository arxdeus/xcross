import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/flutter/flutter_sdk_host_policy.dart';
import 'package:xcross/src/shared/flutter/build/flutter_packer.dart';
import 'package:xcross/src/shared/flutter/build/info_plist.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/flutter_bundle_assembler.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xml/xml.dart';

import '../flutter_test_runtime.dart';

Future<void> _deleteTemp(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } on PathNotFoundException {
    if (directory.existsSync()) rethrow;
  }
}

final class RecordingFlutterSdkPolicy
    implements FlutterSdkHostPolicy<LinuxHost> {
  RecordingFlutterSdkPolicy(this.root);
  final String root;
  final List<String> executables = [];
  @override
  Future<String> rootFromExecutable(
    String executable,
    ProcessRunner<LinuxHost> runner,
  ) async {
    executables.add(executable);
    return root;
  }
}

void main() {
  test('Debug includes and CLI versions reach the final plist values', () async {
    final project = await Directory.systemTemp.createTemp('xcross-plist-');
    addTearDown(() => project.delete(recursive: true));
    File(
      p.join(project.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: example\n');
    final flutter = Directory(p.join(project.path, 'ios', 'Flutter'))
      ..createSync(recursive: true);
    File(p.join(flutter.path, 'Generated.xcconfig')).writeAsStringSync(
      'APP_SUFFIX = \$(inherited)generated\n'
      'BASE = old\n'
      'MARKETING_VERSION = generated-version\n',
    );
    File(p.join(flutter.path, 'Debug.xcconfig')).writeAsStringSync(
      '#include "Generated.xcconfig"\n'
      'APP_SUFFIX[sdk=iphoneos*] = \$(inherited).device\n'
      'DISPLAY_NAME = \$(BASE)\n'
      'BASE = new\n'
      'APP_VERSION = \$(FLUTTER_BUILD_NAME)\n'
      'APP_BUILD = \${FLUTTER_BUILD_NUMBER}\n'
      'SDK_NAME[sdk=iphoneos26.5] = exact-sdk\n'
      'SDK_NAME = generic-sdk\n'
      'CURRENT_PROJECT_VERSION = 2\n',
    );
    final packer = FlutterPacker(
      runtime: testIPhoneRuntime(),
      projectRoot: project.path,
      bundleId: 'com.example.app',
      options: const FlutterBuildOptions(buildName: '5.0', buildNumber: '50'),
    );
    final xml = InfoPlist.expandXmlVars(
      '<plist><dict>'
      r'<key>Name</key><string>$(APP_SUFFIX)</string>'
      r'<key>Display</key><string>$(DISPLAY_NAME)</string>'
      r'<key>AliasVersion</key><string>$(APP_VERSION)</string>'
      r'<key>AliasBuild</key><string>$(APP_BUILD)</string>'
      r'<key>SDKName</key><string>$(SDK_NAME)</string>'
      r'<key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>'
      r'<key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>'
      '</dict></plist>',
      await FlutterBundleAssembler(
        FlutterBuildContext(request: packer.request, flutterRoot: '/flutter'),
      ).buildSubstitutionMap(sdkName: 'iphoneos26.5'),
    );
    final values = XmlDocument.parse(xml).rootElement
        .getElement('dict')!
        .childElements
        .where((entry) => entry.name.local == 'string')
        .map((entry) => entry.innerText)
        .toList();
    expect(values, [
      'generated.device',
      'old',
      '5.0',
      '50',
      'exact-sdk',
      '5.0',
      '50',
    ]);
  });

  test(
    'explicit and configured roots precede environment without global mutation',
    () async {
      final configured = testIPhoneRuntime(
        resolution: const FlutterResolutionConfiguration(
          executable: '/xcross',
          root: '/configured/flutter',
          environmentRoot: '/environment/flutter',
        ),
      );
      expect(
        await configured.resolveFlutterRoot(
          projectRoot: Directory.systemTemp.path,
          root: '/explicit/flutter',
        ),
        '/explicit/flutter',
      );
      expect(
        await configured.resolveFlutterRoot(
          projectRoot: Directory.systemTemp.path,
        ),
        '/configured/flutter',
      );
      final independent = testIPhoneRuntime(
        resolution: const FlutterResolutionConfiguration(
          executable: '/xcross',
          root: '/independent/flutter',
        ),
      );
      expect(
        await independent.resolveFlutterRoot(
          projectRoot: Directory.systemTemp.path,
        ),
        '/independent/flutter',
      );
      expect(
        await configured.resolveFlutterRoot(
          projectRoot: Directory.systemTemp.path,
        ),
        '/configured/flutter',
      );
    },
  );

  test('configured environment precedes FVM and configured tool', () async {
    final project = await Directory.systemTemp.createTemp(
      'flutter-resolution-',
    );
    addTearDown(() => project.delete(recursive: true));
    final sdk = Directory(p.join(project.path, 'sdk'))..createSync();
    Directory(p.join(project.path, '.fvm')).createSync();
    Link(p.join(project.path, '.fvm', 'flutter_sdk')).createSync(sdk.path);
    final runtime = testIPhoneRuntime(
      resolution: const FlutterResolutionConfiguration(
        executable: '/xcross',
        declarative: true,
        environmentRoot: '/environment/flutter',
        tool: '/tool/flutter/bin/flutter',
      ),
    );
    expect(
      await runtime.resolveFlutterRoot(projectRoot: project.path),
      '/environment/flutter',
    );
    final fvm = testIPhoneRuntime(
      resolution: const FlutterResolutionConfiguration(
        executable: '/xcross',
        declarative: true,
        tool: '/tool/flutter/bin/flutter',
      ),
    );
    expect(
      await fvm.resolveFlutterRoot(projectRoot: project.path),
      sdk.resolveSymbolicLinksSync(),
    );
  });

  test(
    'declarative resolution uses configured tool and rejects missing configuration',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'flutter-resolution-',
      );
      addTearDown(() => project.delete(recursive: true));
      final runtime = testIPhoneRuntime(
        resolution: const FlutterResolutionConfiguration(
          executable: '/xcross',
          declarative: true,
          tool: '/configured/flutter/bin/flutter',
        ),
      );
      expect(
        await runtime.resolveFlutterRoot(projectRoot: project.path),
        '/configured/flutter',
      );
      final missing = testIPhoneRuntime(
        resolution: const FlutterResolutionConfiguration(
          executable: '/xcross',
          declarative: true,
        ),
      );
      await expectLater(
        missing.resolveFlutterRoot(projectRoot: project.path),
        throwsA(isA<FlutterBuildError>()),
      );
    },
  );

  test(
    'configured shim executable routes selected host SDK strategy',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'xcross_configured_shim_',
      );
      addTearDown(() => project.deleteSync(recursive: true));
      final configured = p.join(project.path, 'mise', 'shims', 'flutter');
      final expected = p.join(project.path, 'selected-flutter');
      final strategy = RecordingFlutterSdkPolicy(expected);
      final runtime = testIPhoneRuntime(
        sdkHostPolicy: strategy,
        resolution: FlutterResolutionConfiguration(
          executable: '/xcross',
          declarative: true,
          tool: configured,
        ),
      );
      expect(
        await runtime.resolveFlutterRoot(projectRoot: project.path),
        expected,
      );
      expect(strategy.executables, [configured]);
    },
  );

  test('copies every SwiftPM dylib into Frameworks', () async {
    final tmp = await Directory.systemTemp.createTemp('flutter_packer_test-');
    try {
      final frameworks = Directory(p.join(tmp.path, 'Frameworks'))
        ..createSync();
      final aggregate = File(p.join(tmp.path, 'libAggregate.dylib'))
        ..writeAsStringSync('aggregate');
      final dependency = File(p.join(tmp.path, 'libDependency.dylib'))
        ..writeAsStringSync('dependency');

      await testIPhoneRuntime().frameworks.copyPluginLibraries([
        aggregate.path,
        dependency.path,
      ], frameworks.path);

      expect(
        File(
          p.join(frameworks.path, p.basename(aggregate.path)),
        ).readAsStringSync(),
        'aggregate',
      );
      expect(
        File(
          p.join(frameworks.path, p.basename(dependency.path)),
        ).readAsStringSync(),
        'dependency',
      );
    } finally {
      await _deleteTemp(tmp);
    }
  });

  test('copies native-asset frameworks recursively into Frameworks', () async {
    final tmp = await Directory.systemTemp.createTemp('native_framework_test-');
    try {
      final source = Directory(p.join(tmp.path, 'Foo.framework'))..createSync();
      File(p.join(source.path, 'Foo')).writeAsStringSync('binary');
      Directory(p.join(source.path, 'Resources')).createSync();
      File(
        p.join(source.path, 'Resources', 'Info.plist'),
      ).writeAsStringSync('plist');
      final destination = Directory(p.join(tmp.path, 'Frameworks'))
        ..createSync();

      await testIPhoneRuntime().frameworks.copyNativeAssetFrameworks([
        source.path,
      ], destination.path);

      expect(
        File(
          p.join(destination.path, 'Foo.framework', 'Foo'),
        ).readAsStringSync(),
        'binary',
      );
      expect(
        File(
          p.join(destination.path, 'Foo.framework', 'Resources', 'Info.plist'),
        ).readAsStringSync(),
        'plist',
      );
    } finally {
      await _deleteTemp(tmp);
    }
  });
  test('physical and simulator output policies cannot overlap', () {
    final iphone = testIPhoneRuntime().policy;
    final simulator = testSimulatorRuntime().policy;
    expect(iphone.outputDirectory('/project'), '/project/build/xcross-ios');
    expect(
      simulator.outputDirectory('/project'),
      '/project/build/xcross-ios-simulator',
    );
    expect(
      iphone.buildDirectory('/project', 'xcross-flutter-debug'),
      '/project/build/xcross-flutter-debug',
    );
    expect(
      simulator.buildDirectory('/project', 'xcross-flutter-debug'),
      '/project/build/xcross-ios-simulator/xcross-flutter-debug',
    );
    expect(iphone.workspaceSuffix, '');
    expect(simulator.workspaceSuffix, '-simulator');
    expect(
      iphone.binaryArtifactDirectory,
      isNot(simulator.binaryArtifactDirectory),
    );
  });
}
