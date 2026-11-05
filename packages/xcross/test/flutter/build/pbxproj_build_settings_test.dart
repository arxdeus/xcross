import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/pbxproj.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';

void main() {
  const fixture = r'''
  // !$*UTF8*$!
  {
    archiveVersion = 1;
    objects = {
      ROOT = { isa = PBXProject; buildConfigurationList = PLIST; targets = (APP); };
      PLIST = { isa = XCConfigurationList; buildConfigurations = (PDEBUG, PRELEASE, PRELEASEPROD); };
      PDEBUG = { isa = XCBuildConfiguration; name = Debug; buildSettings = { TARGETED_DEVICE_FAMILY = "1,2"; SWIFT_VERSION = 5.0; OTHER = "-a"; }; };
      PRELEASE = { isa = XCBuildConfiguration; name = Release; buildSettings = { TARGETED_DEVICE_FAMILY = "1,2"; SWIFT_VERSION = 5.0; OTHER = "-r"; }; };
      PRELEASEPROD = { isa = XCBuildConfiguration; name = "Release-prod"; buildSettings = { TARGETED_DEVICE_FAMILY = 1; }; };
      APP = { isa = PBXNativeTarget; name = Runner; productType = "com.apple.product-type.application"; buildConfigurationList = TLIST; };
      TLIST = { isa = XCConfigurationList; buildConfigurations = (TDEBUG, TRELEASE, TRELEASEPROD); };
      TDEBUG = { isa = XCBuildConfiguration; name = Debug; buildSettings = { PRODUCT_BUNDLE_IDENTIFIER = dev.debug; SWIFT_VERSION = 6.0; OTHER = "$(inherited) -t"; }; };
      TRELEASE = { isa = XCBuildConfiguration; name = Release; buildSettings = { PRODUCT_BUNDLE_IDENTIFIER = dev.release; CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements; }; };
      TRELEASEPROD = { isa = XCBuildConfiguration; name = "Release-prod"; buildSettings = { PRODUCT_BUNDLE_IDENTIFIER = dev.prod; }; };
    };
    rootObject = ROOT;
  }
  ''';
  final project = PbxProject.parse(fixture, projectDirectory: 'ios');
  final target = project.applicationTarget!;

  String? setting(String key, String configuration) =>
      project.buildSetting(target, key, configuration: configuration);

  test('inherits a setting defined only at project level', () {
    expect(setting('TARGETED_DEVICE_FAMILY', 'Debug'), '1,2');
    expect(setting('TARGETED_DEVICE_FAMILY', 'Release'), '1,2');
  });

  test('target configuration overrides the project configuration', () {
    expect(setting('SWIFT_VERSION', 'Debug'), '6.0');
    expect(setting('SWIFT_VERSION', 'Release'), '5.0');
  });

  test(r'expands $(inherited) with the project value', () {
    expect(setting('OTHER', 'Debug'), '-a -t');
  });

  test('selects the requested configuration, including flavors', () {
    expect(setting('PRODUCT_BUNDLE_IDENTIFIER', 'Debug'), 'dev.debug');
    expect(setting('PRODUCT_BUNDLE_IDENTIFIER', 'Release'), 'dev.release');
    expect(setting('PRODUCT_BUNDLE_IDENTIFIER', 'Release-prod'), 'dev.prod');
    expect(setting('TARGETED_DEVICE_FAMILY', 'Release-prod'), '1');
    expect(setting('CODE_SIGN_ENTITLEMENTS', 'Debug'), isNull);
    expect(
      setting('CODE_SIGN_ENTITLEMENTS', 'Release'),
      'Runner/Runner.entitlements',
    );
  });

  test('maps build mode and flavor to the declared configuration name', () {
    expect(xcodeBaseConfiguration(FlutterBuildMode.profile), 'Profile');
    expect(project.configurationName('Release', 'prod'), 'Release-prod');
    expect(project.configurationName('Release', 'missing'), 'Release');
    expect(project.configurationName('Debug', null), 'Debug');
  });
}
