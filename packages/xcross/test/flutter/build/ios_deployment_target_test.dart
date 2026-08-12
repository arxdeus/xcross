import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp(
      'xcross_ios_deployment_target-',
    );
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<void> writeAppFrameworkInfoPlist(String minimumOsVersion) async {
    final dir = Directory(p.join(tmp.path, 'ios', 'Flutter'));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'AppFrameworkInfo.plist')).writeAsString(
      '<?xml version="1.0"?>\n'
      '<plist version="1.0">\n'
      '<dict>\n'
      '\t<key>MinimumOSVersion</key>\n'
      '\t<string>$minimumOsVersion</string>\n'
      '</dict>\n'
      '</plist>\n',
    );
  }

  Future<void> writePbxproj(
    String content, {
    String xcodeproj = 'Runner.xcodeproj',
  }) async {
    final dir = Directory(p.join(tmp.path, 'ios', xcodeproj));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'project.pbxproj')).writeAsString(content);
  }

  test(
    'resolves deployment target version and build triple from pbxproj',
    () async {
      await writePbxproj('IPHONEOS_DEPLOYMENT_TARGET = 15.6;\n');

      expect(IosDeploymentTarget.resolve(tmp.path).version, '15.6');
      expect(
        IosDeploymentTarget.resolve(tmp.path).buildTriple,
        'arm64-apple-ios15.6',
      );
    },
  );

  test(
    'strips optional quotes around pbxproj deployment target values',
    () async {
      await writePbxproj('IPHONEOS_DEPLOYMENT_TARGET = "14.2";\n');

      expect(IosDeploymentTarget.resolve(tmp.path).version, '14.2');
    },
  );

  test(
    'selects the highest numeric deployment target from multiple values',
    () async {
      await writePbxproj('''
IPHONEOS_DEPLOYMENT_TARGET = 15.6;
IPHONEOS_DEPLOYMENT_TARGET = 15.10;
IPHONEOS_DEPLOYMENT_TARGET = 14.9;
''');

      expect(IosDeploymentTarget.resolve(tmp.path).version, '15.10');
    },
  );

  test(
    r'ignores $(VAR) and malformed pbxproj deployment target values',
    () async {
      await writePbxproj(r'''
IPHONEOS_DEPLOYMENT_TARGET = $(IPHONEOS_DEPLOYMENT_TARGET);
IPHONEOS_DEPLOYMENT_TARGET = ios15;
IPHONEOS_DEPLOYMENT_TARGET = 16.1;
''');

      expect(IosDeploymentTarget.resolve(tmp.path).version, '16.1');
    },
  );

  test('falls back to MinimumOSVersion from AppFrameworkInfo.plist', () async {
    await writePbxproj('IPHONEOS_DEPLOYMENT_TARGET = ios15;\n');
    await writeAppFrameworkInfoPlist('12.4');

    expect(IosDeploymentTarget.resolve(tmp.path).version, '12.4');
  });

  test('uses alternate xcodeproj when Runner.xcodeproj is absent', () async {
    await writePbxproj(
      'IPHONEOS_DEPLOYMENT_TARGET = 17.0;\n',
      xcodeproj: 'App.xcodeproj',
    );

    expect(IosDeploymentTarget.resolve(tmp.path).version, '17.0');
  });

  test(
    'prefers Runner.xcodeproj when alternate xcodeproj also exists',
    () async {
      await writePbxproj(
        'IPHONEOS_DEPLOYMENT_TARGET = 17.0;\n',
        xcodeproj: 'App.xcodeproj',
      );
      await writePbxproj('IPHONEOS_DEPLOYMENT_TARGET = 16.0;\n');

      expect(IosDeploymentTarget.resolve(tmp.path).version, '16.0');
    },
  );

  test(
    'selects alternate xcodeproj deterministically by sorted path',
    () async {
      await writePbxproj(
        'IPHONEOS_DEPLOYMENT_TARGET = 18.0;\n',
        xcodeproj: 'Zed.xcodeproj',
      );
      await writePbxproj(
        'IPHONEOS_DEPLOYMENT_TARGET = 17.0;\n',
        xcodeproj: 'App.xcodeproj',
      );

      expect(IosDeploymentTarget.resolve(tmp.path).version, '17.0');
    },
  );

  test(
    'returns 13.0 fallback when no deployment target source is usable',
    () async {
      await writePbxproj('IPHONEOS_DEPLOYMENT_TARGET = ios15;\n');
      await writeAppFrameworkInfoPlist(r'$(MINIMUM_OS_VERSION)');

      expect(IosDeploymentTarget.resolve(tmp.path).version, '13.0');
      expect(IosDeploymentTarget.fallback.version, '13.0');
    },
  );
}
