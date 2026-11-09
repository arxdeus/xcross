import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/compose/swift/swift_module_index.dart';

void main() {
  late Directory root;
  late String sdk;
  late String resource;

  void dir(String path) =>
      Directory(p.join(root.path, path)).createSync(recursive: true);
  void file(String path, [String content = '']) {
    final f = File(p.join(root.path, path))..createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  SwiftModuleIndex scan({Iterable<String> extra = const []}) =>
      SwiftModuleIndex.scan(
        files: LinuxHost(architecture: 'x64').fileSystem,
        sdkPath: sdk,
        resourceDir: resource,
        platformSdkName: 'iphoneos',
        extraModules: extra,
      );

  setUp(() {
    root = Directory.systemTemp.createTempSync('swift_index_');
    sdk = p.join(root.path, 'sdk');
    resource = p.join(root.path, 'res');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('indexes frameworks, swiftmodules, module maps and resource dir', () {
    dir('sdk/System/Library/Frameworks/SwiftUI.framework/Modules');
    dir('sdk/System/Library/Frameworks/IOKit.framework/Headers');
    dir('sdk/System/Library/SubFrameworks/UIKitCore.framework/Modules');
    dir('sdk/usr/lib/swift/Observation.swiftmodule');
    file('sdk/usr/lib/swift/Swift.swiftinterface');
    file('sdk/usr/include/module.modulemap', '''
// module Commented { }
/* module Block { } */
module Darwin [system] {
  module * { export * }
}
extern module Dispatch "dispatch.modulemap"
''');
    file(
      'sdk/usr/include/CommonCrypto/module.modulemap',
      'framework module CommonCrypto {\n  explicit module Nested {}\n}\n',
    );
    file('sdk/usr/include/extra.modulemap', 'module Extra { header "x.h" }');
    dir('res/iphoneos/Cxx.swiftmodule');
    file('res/clang/include/module.modulemap', 'module _Builtin_stdint {}');

    final index = scan(extra: ['Shared']);
    expect(index.modules, {
      'SwiftUI',
      'UIKitCore',
      'Observation',
      'Swift',
      'Darwin',
      'Dispatch',
      'CommonCrypto',
      'Extra',
      'Cxx',
      '_Builtin_stdint',
      'Shared',
    });
    expect(index.contains('IOKit'), isFalse);
    expect(index.missing(['SwiftUI', 'Zed', 'Alpha', 'Zed']), ['Alpha', 'Zed']);
  });

  test('tolerates missing directories', () {
    expect(scan().modules, isEmpty);
  });

  test('excludes implementation-detail modules and records the owner', () {
    dir('sdk/System/Library/Frameworks/SwiftUI.framework/Modules');
    file(
      'sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/'
          'SwiftUICore.swiftmodule/arm64e-apple-ios.swiftinterface',
      '// swift-interface-format-version: 1.0\n'
          '// swift-module-flags: -target arm64e-apple-ios26.5 '
          '-module-name SwiftUICore\n'
          '// swift-module-flags-ignorable: -user-module-version 7 '
          '-public-module-name SwiftUI -package-name x\n'
          'import Swift\n',
    );
    file(
      'sdk/System/Library/Frameworks/Combine.framework/Modules/'
          'Combine.swiftmodule/arm64e-apple-ios.swiftinterface',
      '// swift-module-flags: -module-name Combine\n',
    );
    final index = scan();
    expect(index.modules, containsAll(['SwiftUI', 'Combine']));
    expect(index.contains('SwiftUICore'), isFalse);
    expect(index.implementationDetailOf, {'SwiftUICore': 'SwiftUI'});
    expect(index.missing(['SwiftUICore', 'SwiftUI']), ['SwiftUICore']);
  });

  test('excludes implementation details under usr/lib/swift too', () {
    file(
      'sdk/usr/lib/swift/_Detail.swiftmodule/arm64-apple-ios.swiftinterface',
      '// swift-module-flags: -module-name _Detail '
          '-public-module-name Owner\n',
    );
    dir('sdk/usr/lib/swift/Owner.swiftmodule');
    final index = scan();
    expect(index.contains('Owner'), isTrue);
    expect(index.contains('_Detail'), isFalse);
    expect(index.implementationDetailOf, {'_Detail': 'Owner'});
  });

  test('counts symlinked framework directories', () {
    dir('real/WebKit.framework/Modules');
    dir('sdk/System/Library/Frameworks');
    Link(
      p.join(root.path, 'sdk/System/Library/Frameworks/WebKit.framework'),
    ).createSync(p.join(root.path, 'real/WebKit.framework'));
    expect(scan().contains('WebKit'), isTrue);
  }, testOn: '!windows');

  test('matches module names case-sensitively, like swiftc', () {
    // swiftc rejects `import uikit` even on case-insensitive filesystems.
    dir('sdk/System/Library/Frameworks/UIKit.framework/Modules');
    final index = scan();
    expect(index.missing(['uikit', 'UIKit']), ['uikit']);
  });

  test('indexes the simulator resource subdir when asked', () {
    dir('res/iphoneos/Cxx.swiftmodule');
    dir('res/iphonesimulator/CxxSim.swiftmodule');
    final index = SwiftModuleIndex.scan(
      files: LinuxHost(architecture: 'x64').fileSystem,
      sdkPath: sdk,
      resourceDir: resource,
      platformSdkName: 'iphonesimulator',
    );
    expect(index.modules, {'CxxSim'});
  });

  test('parses -public-module-name only from module flag comments', () {
    expect(
      SwiftModuleIndex.publicModuleNameFromInterfaceHeader(
        '// swift-module-flags: -O\nlet x = "-public-module-name Nope"\n',
      ),
      isNull,
    );
    expect(
      SwiftModuleIndex.publicModuleNameFromInterfaceHeader(
        '// swift-module-flags-ignorable: -public-module-name RealityKit\r\n',
      ),
      'RealityKit',
    );
  });

  final bundle = p.join(
    Platform.environment['HOME'] ?? '',
    '.config/xcross/swift-sdks/xcross-darwin.artifactbundle',
  );
  final realSdk = p.join(
    bundle,
    'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk',
  );
  test('resolves common modules in the real bundle', () {
    final index = SwiftModuleIndex.scan(
      files: LinuxHost(architecture: 'x64').fileSystem,
      sdkPath: realSdk,
      resourceDir: p.join(
        bundle,
        'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift',
      ),
      platformSdkName: 'iphoneos',
    );
    expect(
      index.missing([
        'SwiftUI',
        'UIKit',
        'Foundation',
        'Combine',
        'SwiftData',
        'CoreGraphics',
        'CoreFoundation',
        'CoreImage',
        'CoreMotion',
        'Observation',
        'os',
        'Dispatch',
        'AVFoundation',
        'MapKit',
        'Darwin',
      ]),
      isEmpty,
    );
    expect(index.implementationDetailOf['SwiftUICore'], 'SwiftUI');
    expect(index.contains('SwiftUICore'), isFalse);
  }, skip: Directory(realSdk).existsSync() ? false : 'no local SDK bundle');
}
