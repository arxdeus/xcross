import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_bundle_resources.dart';
import 'package:xcross/src/flutter/build/pbxproj.dart';

void main() {
  late Directory tmp;
  late Directory project;
  late Directory runner;
  late Directory bundle;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ios_bundle_resources_test-');
    project = Directory(p.join(tmp.path, 'project'))..createSync();
    runner = Directory(p.join(project.path, 'ios', 'Runner'))
      ..createSync(recursive: true);
    bundle = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('finds a uniquely relocated target resource', () async {
    _file(runner, 'ServiceConfig.plist', 'config');
    _writeProject(project, appRefs: ['SERVICE_CONFIG']);

    await _stage(project, bundle);

    expect(
      _bundleFile(bundle, 'ServiceConfig.plist').readAsStringSync(),
      'config',
    );
  });

  test('copies arbitrary resources only from the application target', () async {
    _file(runner, 'Included.plist', 'included');
    _file(runner, 'NotAMember.plist', 'loose');
    _file(runner, 'Extension.plist', 'extension');
    _file(runner, 'Payload/nested/value.txt', 'nested');
    _file(runner, 'Assets.xcassets/Contents.json', '{}');
    _writeProject(project, appRefs: ['INCLUDED', 'PAYLOAD', 'ASSETS']);

    await _stage(project, bundle);

    expect(
      _bundleFile(bundle, 'Included.plist').readAsStringSync(),
      'included',
    );
    expect(
      _bundleFile(bundle, 'Payload/nested/value.txt').readAsStringSync(),
      'nested',
    );
    expect(_bundleFile(bundle, 'NotAMember.plist').existsSync(), isFalse);
    expect(_bundleFile(bundle, 'Extension.plist').existsSync(), isFalse);
    expect(
      Directory(p.join(bundle.path, 'Assets.xcassets')).existsSync(),
      isFalse,
    );
  });

  test('expands localized variant groups and preserves localization', () async {
    _file(runner, 'Base.lproj/Labels.strings', 'base');
    _file(runner, 'fr.lproj/Labels.strings', 'fr');
    _writeProject(project, appRefs: ['VARIANT']);

    await _stage(project, bundle);

    expect(
      _bundleFile(bundle, 'Base.lproj/Labels.strings').readAsStringSync(),
      'base',
    );
    expect(
      _bundleFile(bundle, 'fr.lproj/Labels.strings').readAsStringSync(),
      'fr',
    );
  });

  test(
    'uses adjacent compiled storyboard and puts Base output at root',
    () async {
      _file(runner, 'Base.lproj/Main.storyboard', 'source');
      _file(runner, 'Base.lproj/Main.storyboardc/scene.nib', 'compiled');
      _writeProject(project, appRefs: ['STORYBOARD']);

      await _stage(project, bundle);

      expect(
        _bundleFile(bundle, 'Main.storyboardc/scene.nib').readAsStringSync(),
        'compiled',
      );
      expect(
        Directory(p.join(bundle.path, 'Base.lproj')).existsSync(),
        isFalse,
      );
    },
  );

  test('discovers a non-Runner Xcode project', () async {
    _file(runner, 'Included.plist', 'included');
    _writeProject(project, appRefs: ['INCLUDED'], projectName: 'Custom');

    await _stage(project, bundle);

    expect(
      _bundleFile(bundle, 'Included.plist').readAsStringSync(),
      'included',
    );
  });

  test('skips malformed Runner for a parseable application project', () {
    _writeProject(project, appRefs: [], projectName: 'Custom');
    final runnerProject = Directory(
      p.join(project.path, 'ios', 'Runner.xcodeproj'),
    )..createSync(recursive: true);
    File(
      p.join(runnerProject.path, 'project.pbxproj'),
    ).writeAsStringSync('{ malformed');

    expect(
      PbxProject.findPbxproj(project.path),
      endsWith(p.join('Custom.xcodeproj', 'project.pbxproj')),
    );
  });

  test('prefers an application project over non-app Runner', () {
    _writeProject(
      project,
      appRefs: [],
      productType: 'com.apple.product-type.framework',
    );
    _writeProject(project, appRefs: [], projectName: 'Custom');

    expect(
      PbxProject.findPbxproj(project.path),
      endsWith(p.join('Custom.xcodeproj', 'project.pbxproj')),
    );
  });

  test('falls back deterministically when no project has an app target', () {
    _writeProject(
      project,
      appRefs: [],
      projectName: 'Zeta',
      productType: 'com.apple.product-type.framework',
    );
    _writeProject(
      project,
      appRefs: [],
      projectName: 'Alpha',
      productType: 'com.apple.product-type.framework',
    );

    expect(
      PbxProject.findPbxproj(project.path),
      endsWith(p.join('Alpha.xcodeproj', 'project.pbxproj')),
    );
  });

  test('stages synchronized application resources conservatively', () async {
    _file(runner, 'Payload/nested/value.txt', 'resource');
    _file(runner, 'Source.swift', 'source');
    _file(runner, 'Info.plist', 'plist');
    _file(runner, 'Settings.plist', 'settings');
    _file(runner, 'Excluded.txt', 'excluded');
    _writeProject(
      project,
      appRefs: [],
      synchronized: true,
      exceptions: ['Excluded.txt'],
    );

    await _stage(project, bundle);

    expect(_bundleFile(bundle, 'value.txt').readAsStringSync(), 'resource');
    expect(_bundleFile(bundle, 'Source.swift').existsSync(), isFalse);
    expect(_bundleFile(bundle, 'Info.plist').existsSync(), isFalse);
    expect(
      _bundleFile(bundle, 'Settings.plist').readAsStringSync(),
      'settings',
    );
    expect(_bundleFile(bundle, 'Excluded.txt').existsSync(), isFalse);
  });

  test(
    'excludes target Info.plist but copies another plist resource',
    () async {
      _file(runner, 'Info.plist', 'info');
      _file(runner, 'Settings.plist', 'settings');
      _file(project, 'ios/Flutter/AppFrameworkInfo.plist', 'framework input');
      _writeProject(project, appRefs: ['INFO', 'SETTINGS', 'FRAMEWORK_INFO']);

      await _stage(project, bundle);

      expect(_bundleFile(bundle, 'Info.plist').existsSync(), isFalse);
      expect(
        _bundleFile(bundle, 'AppFrameworkInfo.plist').existsSync(),
        isFalse,
      );
      expect(
        _bundleFile(bundle, 'Settings.plist').readAsStringSync(),
        'settings',
      );
    },
  );
}

Future<void> _stage(Directory project, Directory bundle) =>
    stageIosBundleResources(projectRoot: project.path, bundleDir: bundle.path);

File _bundleFile(Directory bundle, String relative) =>
    File(p.join(bundle.path, relative));

void _file(Directory root, String relative, String contents) {
  final file = File(p.join(root.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

void _writeProject(
  Directory project, {
  required List<String> appRefs,
  String projectName = 'Runner',
  bool synchronized = false,
  List<String> exceptions = const [],
  String productType = 'com.apple.product-type.application',
}) {
  final xcodeproj = Directory(
    p.join(project.path, 'ios', '$projectName.xcodeproj'),
  )..createSync(recursive: true);
  const references = {
    'INCLUDED': 'Included.plist',
    'PAYLOAD': 'Payload',
    'ASSETS': 'Assets.xcassets',
    'INFO': 'Info.plist',
    'SETTINGS': 'Settings.plist',
    'FRAMEWORK_INFO': '../Flutter/AppFrameworkInfo.plist',
    'STORYBOARD': 'Base.lproj/Main.storyboard',
    'SERVICE_CONFIG': 'ServiceConfig.plist',
  };
  final objects = StringBuffer(r'''
// !$*UTF8*$!
{
  rootObject = PROJECT;
  objects = {
    PROJECT = { isa = PBXProject; };
    RUNNER_GROUP = { isa = PBXGroup; path = Runner; children = (
      INCLUDED, PAYLOAD, ASSETS, INFO, SETTINGS, STORYBOARD, VARIANT,
    ); };
    FLUTTER_GROUP = { isa = PBXGroup; path = Flutter; children = (FRAMEWORK_INFO); };
''');
  for (final entry in references.entries) {
    objects.writeln(
      '    ${entry.key} = { isa = PBXFileReference; path = ${entry.value}; sourceTree = "<group>"; };',
    );
  }
  objects.write('''
    VARIANT = { isa = PBXVariantGroup; path = Labels.strings; children = (BASE_LABELS, FR_LABELS); };
    BASE_LABELS = { isa = PBXFileReference; path = Base.lproj/Labels.strings; sourceTree = "<group>"; };
    FR_LABELS = { isa = PBXFileReference; path = fr.lproj/Labels.strings; sourceTree = "<group>"; };
    APP_CONFIG_LIST = { isa = XCConfigurationList; buildConfigurations = (APP_CONFIG); };
    APP_CONFIG = { isa = XCBuildConfiguration; name = Debug; buildSettings = { INFOPLIST_FILE = Runner/Info.plist; }; };
    APP_TARGET = { isa = PBXNativeTarget; productType = $productType; buildConfigurationList = APP_CONFIG_LIST; buildPhases = (APP_RESOURCES); ${synchronized ? 'fileSystemSynchronizedGroups = (SYNC_GROUP);' : ''} };
    ${synchronized ? 'SYNC_GROUP = { isa = PBXFileSystemSynchronizedRootGroup; path = Runner; sourceTree = SOURCE_ROOT; exceptions = (SYNC_EXCEPTIONS); };\n    SYNC_EXCEPTIONS = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; target = APP_TARGET; membershipExceptions = (${exceptions.join(', ')}); };' : ''}
    APP_RESOURCES = { isa = PBXResourcesBuildPhase; files = (
''');
  for (final ref in appRefs) {
    objects.writeln('      APP_BUILD_$ref,');
  }
  objects.write('''
    ); };
    EXT_TARGET = { isa = PBXNativeTarget; productType = com.apple.product-type.app-extension; buildPhases = (EXT_RESOURCES); };
    EXT_RESOURCES = { isa = PBXResourcesBuildPhase; files = (EXT_BUILD); };
    EXTENSION = { isa = PBXFileReference; path = Runner/Extension.plist; sourceTree = SOURCE_ROOT; };
    EXT_BUILD = { isa = PBXBuildFile; fileRef = EXTENSION; };
''');
  for (final ref in appRefs) {
    objects.writeln(
      '    APP_BUILD_$ref = { isa = PBXBuildFile; fileRef = $ref; };',
    );
  }
  objects.write('''
  };
}
''');
  File(p.join(xcodeproj.path, 'project.pbxproj')).writeAsStringSync('$objects');
}
