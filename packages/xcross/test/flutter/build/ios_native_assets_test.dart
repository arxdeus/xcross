import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shim_templates.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_hook_discovery.dart';
import 'package:xcross/src/flutter/errors.dart';

void main() {
  test('detects build hooks through package_config root URIs', () async {
    final tmp = await Directory.systemTemp.createTemp('hook_detection_test-');
    try {
      final package = Directory(p.join(tmp.path, 'dependency'))..createSync();
      Directory(p.join(package.path, 'hook')).createSync();
      File(p.join(package.path, 'hook', 'build.dart')).writeAsStringSync('');
      final dartTool = Directory(p.join(tmp.path, 'app', '.dart_tool'))
        ..createSync(recursive: true);
      File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync('''
{"configVersion":2,"packages":[{"name":"dependency","rootUri":"../../dependency","packageUri":"lib/"}]}
''');

      expect(hasNativeAssetsBuildHooks(p.join(tmp.path, 'app')), isTrue);
      File(p.join(package.path, 'hook', 'build.dart')).deleteSync();
      expect(hasNativeAssetsBuildHooks(p.join(tmp.path, 'app')), isFalse);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('reports malformed package config clearly', () async {
    final tmp = await Directory.systemTemp.createTemp('hook_detection_test-');
    try {
      final dartTool = Directory(p.join(tmp.path, '.dart_tool'))
        ..createSync(recursive: true);
      File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync('{');

      expect(
        () => hasNativeAssetsBuildHooks(tmp.path),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            contains('malformed JSON'),
          ),
        ),
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('detects all FAT Mach-O binaries', () async {
    final tmp = await Directory.systemTemp.createTemp('fat_macho_test-');
    try {
      for (final magic in const <List<int>>[
        [0xca, 0xfe, 0xba, 0xbe],
        [0xbe, 0xba, 0xfe, 0xca],
        [0xca, 0xfe, 0xba, 0xbf],
        [0xbf, 0xba, 0xfe, 0xca],
      ]) {
        final fat = File(p.join(tmp.path, 'fat-${magic.first}'))
          ..writeAsBytesSync(magic);
        expect(await isFatMachO(fat.path), isTrue);
      }
      final thin = File(p.join(tmp.path, 'thin'))
        ..writeAsBytesSync([0xcf, 0xfa, 0xed, 0xfe]);
      expect(await isFatMachO(thin.path), isFalse);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('PowerShell xcrun forwards an empty argument tail safely', () {
    final script = renderPowerShellXcrunShim(
      iosSdk: r'C:\SDK',
      tools: const {'lipo': r'C:\LLVM\lipo.exe'},
    );

    expect(script, contains(r'$tail = if ($i + 1 -lt $Arguments.Count)'));
    expect(script, contains('else { @() }'));
    expect(script, contains(r'& $tool @tail'));
    expect(
      script,
      isNot(contains(r'@($Arguments[($i + 1)..($Arguments.Count - 1)])')),
    );
  });

  test('Apple tool shims expose the Darwin SDK and configured tools', () async {
    if (Platform.isWindows) return;
    final tmp = await Directory.systemTemp.createTemp('apple_shims_test-');
    try {
      await installAppleToolShims(
        tmp.path,
        const AppleToolShimConfig(
          iosSdk: '/sdk/iPhoneOS.sdk',
          clang: '/bin/echo',
          hostCompiler: '/bin/echo',
          archiver: '/toolchain/llvm-ar',
          linker: '/toolchain/ld64.lld',
          deploymentTarget: '15.6',
          lipo: '/bin/echo',
          otool: '/bin/echo',
          installNameTool: '/bin/echo',
        ),
      );
      final xcrun = p.join(tmp.path, 'xcrun');
      final xcrunContents = File(xcrun).readAsStringSync();
      expect(xcrunContents, contains("'/sdk/iPhoneOS.sdk'"));
      expect(xcrunContents, contains("'${p.join(tmp.path, 'clang')}'"));
      expect(xcrunContents, isNot(contains('XCROSS_')));

      expect(
        (await Process.run(
          xcrun,
          ['--sdk', 'iphoneos', '--show-sdk-path'],
          environment: const {},
          includeParentEnvironment: false,
        )).stdout.toString().trim(),
        '/sdk/iPhoneOS.sdk',
      );
      expect(
        (await Process.run(
          xcrun,
          ['--show-sdk-path', '--sdk', 'iphoneos'],
          environment: const {},
          includeParentEnvironment: false,
        )).stdout.toString().trim(),
        '/sdk/iPhoneOS.sdk',
      );
      expect(
        (await Process.run(
          xcrun,
          ['--find', 'clang'],
          environment: const {},
          includeParentEnvironment: false,
        )).stdout.toString().trim(),
        p.join(tmp.path, 'clang'),
      );
      final xcrunClang = await Process.run(
        xcrun,
        ['--sdk', 'iphoneos', 'clang', '-arch', 'arm64', 'asset.c'],
        environment: const {},
        includeParentEnvironment: false,
      );
      expect(xcrunClang.exitCode, 0);
      expect(
        xcrunClang.stdout.toString().trim(),
        '--target=arm64-apple-ios15.6 -isysroot /sdk/iPhoneOS.sdk '
        '-miphoneos-version-min=15.6 -fuse-ld=lld '
        '--ld-path=/toolchain/ld64.lld -arch arm64 asset.c',
      );
      final hostCc = await Process.run(
        'cc',
        const ['-m64', '-Wl,--as-needed', 'host.c'],
        environment: {'PATH': tmp.path},
        includeParentEnvironment: false,
      );
      expect(hostCc.exitCode, 0);
      expect(hostCc.stdout.toString().trim(), '-m64 -Wl,--as-needed host.c');

      final plainCc = await Process.run(
        'cc',
        [
          '-target',
          'arm64-apple-ios15.6',
          '-isysroot',
          '/custom.sdk',
          '--ld-path=/custom/ld',
          'asset.c',
        ],
        // Rust build subprocesses sanitize the hook environment, retaining
        // PATH but not xcross-specific variables. Plain cc must still resolve
        // to the shim, whose cross configuration is embedded in the script.
        environment: {'PATH': tmp.path},
        includeParentEnvironment: false,
      );
      expect(plainCc.exitCode, 0);
      expect(
        plainCc.stdout.toString().trim(),
        '-miphoneos-version-min=15.6 -fuse-ld=lld -target '
        'arm64-apple-ios15.6 -isysroot /custom.sdk '
        '--ld-path=/custom/ld asset.c',
      );
      expect(
        (await Process.run(
          xcrun,
          ['--sdk', 'iphoneos', 'lipo', '-info', 'asset.dylib'],
          environment: const {},
          includeParentEnvironment: false,
        )).stdout.toString().trim(),
        '-info asset.dylib',
      );
      expect(
        (await Process.run(
          p.join(tmp.path, 'otool'),
          ['-L', 'asset.dylib'],
          environment: const {},
          includeParentEnvironment: false,
        )).stdout.toString().trim(),
        '-L asset.dylib',
      );
      expect(
        (await Process.run(
          p.join(tmp.path, 'install_name_tool'),
          ['-id', '@rpath/asset.dylib', 'asset.dylib'],
          environment: const {},
          includeParentEnvironment: false,
        )).stdout.toString().trim(),
        '-id @rpath/asset.dylib asset.dylib',
      );
      expect(
        (await Process.run(
          p.join(tmp.path, 'codesign'),
          const [],
          environment: const {},
          includeParentEnvironment: false,
        )).exitCode,
        0,
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}
