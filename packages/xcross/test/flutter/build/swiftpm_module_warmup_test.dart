import 'dart:io';

import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/module_warmup.dart';

import 'swiftpm_test_context.dart';

final _runtime = testSwiftPmRuntime();

/// Windows builds run without Clang's implicit module locks, so parallel
/// frontends used to build `UIKit.pcm` (and `ImageIO.pcm`, ...) at the same
/// time and collide in the shared module cache. The warm-up target builds
/// those modules once, in one process, before the parallel build.
void main() {
  late Directory temp;
  late SwiftPmModuleWarmup warmup;
  late String sdk;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('xcross-warmup-');
    warmup = SwiftPmModuleWarmup(
      fileSystem: PosixSwiftPmArtifactFileSystem(_runtime.host),
    );
    sdk = p.join(temp.path, 'iPhoneOS.sdk');
    for (final framework in [
      'Foundation',
      'UIKit',
      'ImageIO',
      'WebKit',
      'Security',
      'AVFoundation',
    ]) {
      Directory(
        p.join(sdk, 'System', 'Library', 'Frameworks', '$framework.framework'),
      ).createSync(recursive: true);
    }
  });
  tearDown(() => temp.delete(recursive: true));

  void write(String relative, String content) =>
      File(p.join(temp.path, relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  group('importedModules', () {
    test('reads Swift, Objective-C module and framework imports', () {
      const source = '''
import UIKit
@_implementationOnly import WebKit
@preconcurrency import Security
import struct Foundation.URL
  @import AVFoundation;
#import <ImageIO/ImageIO.h>
#include <Flutter/Flutter.h>
#import "Local.h"
// import NotThis
''';
      expect(
        SwiftPmModuleWarmup.importedModules(source).toSet(),
        containsAll([
          'UIKit',
          'WebKit',
          'Security',
          'Foundation',
          'AVFoundation',
          'ImageIO',
          'Flutter',
        ]),
      );
      expect(
        SwiftPmModuleWarmup.importedModules(source),
        isNot(contains('Local')),
      );
    });
  });

  group('sdkModules', () {
    test('keeps only SDK frameworks, plus the baseline', () async {
      write(
        'Packages/a/Sources/A/A.swift',
        'import WebKit\nimport A_Private\n',
      );
      write(
        'Packages/a/Sources/A/include/A.h',
        '#import <ImageIO/ImageIO.h>\n',
      );
      write('checkouts/b/Sources/B/B.m', '@import Security;\n');
      final modules = await warmup.sdkModules(
        roots: [p.join(temp.path, 'Packages'), p.join(temp.path, 'checkouts')],
        iosSdk: sdk,
      );
      expect(modules, [
        'Flutter',
        'Foundation',
        'ImageIO',
        'Security',
        'UIKit',
        'WebKit',
      ]);
    });

    test('skips tests, examples, .build and .git', () async {
      for (final dir in ['Tests', 'Example', '.build', '.git']) {
        write('Packages/a/$dir/X.swift', 'import AVFoundation\n');
      }
      final modules = await warmup.sdkModules(
        roots: [p.join(temp.path, 'Packages')],
        iosSdk: sdk,
      );
      expect(modules, isNot(contains('AVFoundation')));
    });

    test('tolerates missing roots', () async {
      expect(
        await warmup.sdkModules(
          roots: [p.join(temp.path, 'missing')],
          iosSdk: sdk,
        ),
        SwiftPmModuleWarmup.baselineModules,
      );
    });
  });

  test('guards every import so an unavailable module cannot fail it', () {
    final source = SwiftPmModuleWarmup.source(['UIKit', 'WebKit']);
    expect(source, contains('#if canImport(UIKit)\nimport UIKit\n#endif\n'));
    expect(source, contains('#if canImport(WebKit)\nimport WebKit\n#endif\n'));
  });

  test('refresh writes the warm-up source for the scanned modules', () async {
    write('Packages/a/Sources/A/A.swift', 'import WebKit\n');
    final pluginsDir = p.join(temp.path, 'Plugins');
    final written = <String, String>{};
    await warmup.refresh(
      pluginsDir: pluginsDir,
      roots: [p.join(temp.path, 'Packages')],
      iosSdk: sdk,
      write: (path, content) async => written[path] = content,
    );
    expect(written.keys, [SwiftPmModuleWarmup.sourceFile(pluginsDir)]);
    expect(written.values.single, contains('import WebKit'));
  });

  group('plugins manifest', () {
    const target = IosDeploymentTarget('15.6', platform: IPhoneBuildPlatform());

    test('adds a standalone single-frontend warm-up target on request', () {
      final manifest = SwiftPmManifest.pluginsManifest(
        const [],
        'FlutterFramework',
        deploymentTarget: target,
        moduleWarmup: true,
      );
      expect(manifest, contains('name: "$moduleWarmupTargetName"'));
      expect(
        manifest,
        contains('.unsafeFlags(["-wmo", "-no-emit-module-separately-wmo"])'),
      );
      // Not part of the product, so it never links into the plugins dylib.
      expect(manifest, contains('targets: ["FlutterPluginsGenerated"])'));
    });

    test('leaves the warm-up target out by default', () {
      expect(
        SwiftPmManifest.pluginsManifest(
          const [],
          'FlutterFramework',
          deploymentTarget: target,
        ),
        isNot(contains(moduleWarmupTargetName)),
      );
    });
  });

  test('only Windows warms the module cache', () {
    expect(_runtime.hostPolicy.warmsImplicitModules, isFalse);
    expect(testWindowsSwiftPmRuntime().hostPolicy.warmsImplicitModules, isTrue);
  });
}
