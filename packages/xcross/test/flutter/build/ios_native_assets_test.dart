import 'dart:convert';

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shim_templates.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/flutter_tool_workspace.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_hook_discovery.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/errors.dart';

void main() {
  test(
    'creates a writable Flutter tool workspace without changing SDK',
    () async {
      if (Platform.isWindows) return;
      final tmp = await Directory.systemTemp.createTemp(
        'flutter_workspace_test-',
      );
      try {
        final flutterRoot = p.join(tmp.path, 'flutter');
        final cacheRoot = p.join(tmp.path, 'cache');
        final sdkCache = Directory(p.join(flutterRoot, 'bin', 'cache'))
          ..createSync(recursive: true);
        Directory(p.join(flutterRoot, 'packages')).createSync();
        File(
          p.join(flutterRoot, 'bin', 'flutter'),
        ).writeAsStringSync('flutter');
        File(p.join(flutterRoot, 'bin', 'internal', 'engine.version'))
          ..createSync(recursive: true)
          ..writeAsStringSync('engine-hash\n');
        File(
          p.join(sdkCache.path, 'flutter_tools.snapshot'),
        ).writeAsStringSync('snapshot');
        Directory(p.join(sdkCache.path, 'dart-sdk')).createSync();
        final engineCache = IosEngineCache(
          flutterRoot: flutterRoot,
          cacheRoot: cacheRoot,
        );
        Directory(engineCache.flutterXcframework).createSync(recursive: true);
        final before = await _tree(flutterRoot);

        final workspace = await FlutterToolWorkspace.create(
          flutterRoot: flutterRoot,
          engineCache: engineCache,
        );

        expect(workspace.flutterRoot, isNot(flutterRoot));
        expect(
          await Directory(
            p.join(workspace.flutterRoot, 'packages'),
          ).resolveSymbolicLinks(),
          await Directory(
            p.join(flutterRoot, 'packages'),
          ).resolveSymbolicLinks(),
        );
        expect(
          File(
            p.join(workspace.flutterRoot, 'bin', 'internal', 'engine.version'),
          ).readAsStringSync(),
          'engine-hash\n',
        );
        expect(
          Directory(
            p.join(
              workspace.flutterRoot,
              'bin',
              'cache',
              'artifacts',
              'engine',
              'ios',
              'Flutter.xcframework',
            ),
          ).existsSync(),
          isTrue,
        );
        expect(await _tree(flutterRoot), before);
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

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

  test('normalizes native asset framework install names', () async {
    final tmp = await Directory.systemTemp.createTemp('native_framework_test-');
    try {
      final asset = Directory(p.join(tmp.path, 'Asset.framework'))
        ..createSync();
      final dependency = Directory(p.join(tmp.path, 'Dependency.framework'))
        ..createSync();
      final assetBytes = _dylibMachO([
        '/very/long/native/assets/path/libAsset.dylib',
        '/very/long/native/assets/path/libDependency.dylib',
      ]);
      final dependencyBytes = _dylibMachO([
        '/very/long/native/assets/path/libDependency.dylib',
      ]);

      File(p.join(asset.path, 'Asset')).writeAsBytesSync(assetBytes);
      File(
        p.join(dependency.path, 'Dependency'),
      ).writeAsBytesSync(dependencyBytes);

      await normalizeNativeAssetInstallNames([asset.path, dependency.path]);

      expect(_dylibNames(File(p.join(asset.path, 'Asset')).readAsBytesSync()), [
        '@rpath/Asset.framework/Asset',
        '@rpath/Dependency.framework/Dependency',
      ]);
      expect(
        _dylibNames(
          File(p.join(dependency.path, 'Dependency')).readAsBytesSync(),
        ),
        ['@rpath/Dependency.framework/Dependency'],
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

  test('falls back from llvm-otool to llvm-objdump', () async {
    final requested = <String>[];
    final result = await resolveOtool(
      find: (name) async {
        requested.add(name);
        return name == 'llvm-objdump' ? '/llvm/llvm-objdump' : null;
      },
    );

    expect(requested, ['llvm-otool', 'llvm-objdump']);
    expect(result?.executable, '/llvm/llvm-objdump');
    expect(result?.usesObjdump, isTrue);
  });

  test('translates otool options for llvm-objdump', () {
    final unix = renderUnixOtoolShim(tool: '/llvm/objdump', usesObjdump: true);
    final windows = renderPowerShellOtoolShim(
      tool: r'C:\LLVM\llvm-objdump.exe',
      usesObjdump: true,
    );

    for (final translation in [
      '--macho --dylibs-used',
      '--macho --dylib-id',
      '--macho --private-headers',
    ]) {
      expect(unix, contains(translation));
    }
    for (final translation in [
      "@('--macho', '--dylibs-used')",
      "@('--macho', '--dylib-id')",
      "@('--macho', '--private-headers')",
    ]) {
      expect(windows, contains(translation));
    }
  });

  test('Windows compiler shim strips carriage returns from arguments', () {
    final shim = renderPowerShellCompilerShim(
      iosSdk: r'C:\SDK',
      clang: r'C:\LLVM\clang.exe',
      hostCompiler: r'C:\LLVM\clang.exe',
      linker: r'C:\LLVM\ld64.lld.exe',
      deploymentTarget: '13.0',
    );

    expect(
      shim,
      contains(r'$Arguments = @($args | ForEach-Object { $_.TrimEnd('),
    );
    expect(
      shim,
      contains("'-Wl,-arch,arm64', '-Wl,-platform_version,ios,13.0,26.5'"),
    );
    expect(shim, contains(r'& $compiler @compilerArguments'));
  });

  test('Windows uses the resolved clang as its host C compiler', () async {
    expect(
      await resolveHostCompiler(
        r'C:\Program Files\LLVM\bin\clang.exe',
        windows: true,
      ),
      r'C:\Program Files\LLVM\bin\clang.exe',
    );
  });

  test('Windows resolves xcross as the tool forwarder', () async {
    expect(
      await resolveNativeAssetToolForwarder(
        r'C:\bundle\xcross.exe',
        windows: true,
        findInstalled: () async => fail('must not search'),
      ),
      r'C:\bundle\xcross.exe',
    );
    expect(
      await resolveNativeAssetToolForwarder(
        r'C:\flutter\bin\cache\dart-sdk\bin\dart.exe',
        windows: true,
        findInstalled: () async => r'C:\installed\xcross.exe',
      ),
      r'C:\installed\xcross.exe',
    );
    expect(
      await resolveNativeAssetToolForwarder(
        r'C:\flutter\bin\cache\dart-sdk\bin\dartaotruntime',
        windows: true,
        findInstalled: () async => null,
      ),
      isNull,
    );
  });

  test('Windows exposes a recognizable clang executable forwarder', () async {
    final tmp = await Directory.systemTemp.createTemp('apple_shims_test-');
    try {
      final forwarder = File(p.join(tmp.path, 'xcross.exe'))
        ..writeAsStringSync('forwarder');
      final xcrun = File(p.join(tmp.path, 'source-xcrun.exe'))
        ..writeAsStringSync('xcrun');
      final shims = Directory(p.join(tmp.path, 'shims'));

      await installAppleToolShims(
        shims.path,
        AppleToolShimConfig(
          iosSdk: r'C:\SDK\iPhoneOS.sdk',
          clang: r'C:\LLVM\clang.exe',
          hostCompiler: r'C:\LLVM\clang.exe',
          archiver: r'C:\LLVM\llvm-ar.exe',
          linker: r'C:\LLVM\ld64.lld.exe',
          deploymentTarget: '13.0',
          lipo: r'C:\LLVM\llvm-lipo.exe',
          otool: null,
          installNameTool: null,
          xcrun: xcrun.path,
        ),
        toolForwarderExecutable: forwarder.path,
        windows: true,
      );

      final clang = File(p.join(shims.path, 'clang.exe'));
      expect(clang.existsSync(), isTrue);
      expect(
        File('${clang.path}.path').readAsStringSync(),
        r'C:\LLVM\clang.exe',
      );
      expect(
        jsonDecode(File('${clang.path}.args').readAsStringSync()),
        contains(r'--ld-path=C:\LLVM\ld64.lld.exe'),
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('Apple tool shims expose configured tools including xcrun', () async {
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
          otool: OtoolConfig('/bin/echo', usesObjdump: false),
          installNameTool: '/bin/echo',
          xcrun: '/bin/echo',
        ),
        toolForwarderExecutable: Platform.resolvedExecutable,
      );
      expect(File(p.join(tmp.path, 'xcrun')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'plutil')).existsSync(), isTrue);
      final xcrun = await Process.run(
        'xcrun',
        const ['--show-sdk-path'],
        environment: {'PATH': tmp.path},
        includeParentEnvironment: false,
      );
      expect(xcrun.exitCode, 0);
      expect(xcrun.stdout.toString().trim(), '--show-sdk-path');

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

Future<List<String>> _tree(String root) async {
  final entries = await Directory(root)
      .list(recursive: true, followLinks: false)
      .map((entity) => p.relative(entity.path, from: root))
      .toList();
  entries.sort();
  return entries;
}

Uint8List _dylibMachO(List<String> names) {
  final encoded = names.map(utf8.encode).toList();
  final sizes = [for (final name in encoded) (24 + name.length + 1 + 7) & ~7];
  final commandsSize = sizes.fold(0, (sum, size) => sum + size);
  final bytes = Uint8List(32 + commandsSize);
  final data = ByteData.sublistView(bytes)
    ..setUint32(0, 0xfeedfacf, Endian.little)
    ..setUint32(16, names.length, Endian.little)
    ..setUint32(20, commandsSize, Endian.little);
  var offset = 32;
  for (var index = 0; index < names.length; index++) {
    data
      ..setUint32(offset, index == 0 ? 0x0d : 0x0c, Endian.little)
      ..setUint32(offset + 4, sizes[index], Endian.little)
      ..setUint32(offset + 8, 24, Endian.little);
    bytes.setRange(
      offset + 24,
      offset + 24 + encoded[index].length,
      encoded[index],
    );
    offset += sizes[index];
  }
  return bytes;
}

List<String> _dylibNames(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final count = data.getUint32(16, Endian.little);
  final names = <String>[];
  var offset = 32;
  for (var index = 0; index < count; index++) {
    final size = data.getUint32(offset + 4, Endian.little);
    final start = offset + data.getUint32(offset + 8, Endian.little);
    var end = start;
    while (bytes[end] != 0) {
      end++;
    }
    names.add(utf8.decode(bytes.sublist(start, end)));
    offset += size;
  }
  return names;
}
