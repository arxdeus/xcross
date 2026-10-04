import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer_posix.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_templates_posix.dart';
import 'package:xcross/src/host/windows/flutter/apple_tool_shim_templates.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';

import 'support/native_flutter_fixtures.dart';

void main() {
  test(
    'simulator compiler shim preserves explicit simulator deployment and host work',
    () async {
      if (Platform.isWindows) return;
      final temp = await Directory.systemTemp.createTemp(
        'simulator-compiler-shim-',
      );
      try {
        final shim = File(p.join(temp.path, 'clang'));
        await shim.writeAsString(
          renderUnixCompilerShim(
            iosSdk: '/simulator-sdk',
            clang: '/bin/echo',
            hostCompiler: '/bin/echo',
            linker: '/ld64.lld',
            deploymentTarget: '15.0',
            target: const SimulatorBuildPlatform(),
          ),
        );
        final simulator = await Process.run('/bin/sh', [
          shim.path,
          '-arch',
          'arm64',
          '-c',
          'probe.c',
        ]);
        expect(simulator.exitCode, 0);
        expect(
          simulator.stdout,
          contains('--target=arm64-apple-ios15.0-simulator'),
        );
        expect(simulator.stdout, contains('-mios-simulator-version-min=15.0'));
        expect(simulator.stdout, isNot(contains('-miphoneos-version-min')));
        final explicit = await Process.run('/bin/sh', [
          shim.path,
          '-target',
          'arm64-apple-ios16.0-simulator',
          '-mios-simulator-version-min=16.0',
          '-c',
          'probe.c',
        ]);
        expect(explicit.stdout, contains('-mios-simulator-version-min=16.0'));
        expect(explicit.stdout, isNot(contains('-version-min=15.0')));
        final host = await Process.run('/bin/sh', [shim.path, '-c', 'host.c']);
        expect(host.stdout.toString().trim(), '-c host.c');
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

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

  test('Unix host compiler prefix arguments are shell quoted', () async {
    final temp = await Directory.systemTemp.createTemp('host-prefix-shim-');
    addTearDown(() => temp.delete(recursive: true));
    final shim = File(p.join(temp.path, 'clang'))
      ..writeAsStringSync(
        renderUnixCompilerShim(
          target: const IPhoneBuildPlatform(),
          iosSdk: '/simulator-sdk',
          clang: '/cross/clang',
          hostCompiler: '/usr/bin/printf',
          hostCompilerArguments: ['<%s>', "prefix with spaces and 'quotes'"],
          linker: '/ld64.lld',
          deploymentTarget: '15.0',
        ),
      );
    final result = await Process.run('/bin/sh', [shim.path, '-c', 'host.c']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout, "<prefix with spaces and 'quotes'><-c><host.c>");
  }, skip: Platform.isWindows);

  test(
    'macOS installed compiler shim builds native host with Xcode-first PATH',
    () async {
      final temp = await Directory.systemTemp.createTemp('macos-host-shim-');
      addTearDown(() => temp.delete(recursive: true));
      final selection = await Process.run('/usr/bin/xcode-select', ['-p']);
      expect(selection.exitCode, 0, reason: selection.stderr.toString());
      final developer = Link(p.join(temp.path, 'chosen developer'))
        ..createSync(selection.stdout.toString().trim());
      final environment = Map<String, String>.of(Platform.environment)
        ..remove('SDKROOT')
        ..['DEVELOPER_DIR'] = developer.path;
      final native = await Process.run(
        '/usr/bin/xcrun',
        ['--sdk', 'macosx', '--find', 'clang'],
        environment: environment,
        includeParentEnvironment: false,
      );
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final iosSdk = await Process.run(
        '/usr/bin/xcrun',
        ['--sdk', 'iphonesimulator', '--show-sdk-path'],
        environment: environment,
        includeParentEnvironment: false,
      );
      expect(iosSdk.exitCode, 0, reason: iosSdk.stderr.toString());
      environment['PATH'] =
          '${p.dirname(native.stdout.toString().trim())}:/usr/bin:/bin';
      final compilerHost = MacOSHost(architecture: 'arm64');
      final compiler = await MacOSNativeHostTools(
        compilerHost,
        ProcessRunner(
          compilerHost,
          log: nativeTestLog(),
          stdinStream: const Stream<List<int>>.empty(),
          stdoutSink: nativeTestSink(),
          stderrSink: nativeTestSink(),
        ),
      ).compiler('/cross/clang');
      final shims = p.join(temp.path, 'shims');
      await installAppleToolShims(
        shims,
        AppleToolShimConfig(
          iosSdk: '/cross/iPhoneSimulator.sdk',
          clang: '/cross/clang',
          hostCompiler: compiler.executable,
          hostCompilerArguments: compiler.arguments,
          archiver: '/cross/ar',
          linker: '/cross/ld',
          lipo: '/cross/lipo',
          otool: null,
          installNameTool: null,
          xcrun: '/usr/bin/xcrun',
          deploymentTarget: '15.0',
          target: const SimulatorBuildPlatform(),
        ),
        renderer: PosixAppleToolShimRenderer(LinuxHost(architecture: 'arm64')),
      );
      final source = File(p.join(temp.path, 'host.c'))
        ..writeAsStringSync(
          '#include <stdio.h>\nint main(void) { puts("native host"); return 0; }\n',
        );
      for (final sdkRoot in <String?>[null, iosSdk.stdout.toString().trim()]) {
        final executable = p.join(
          temp.path,
          sdkRoot == null ? 'clean-host' : 'polluted-host',
        );
        final result = await Process.run(
          p.join(shims, 'cc'),
          [source.path, '-o', executable],
          environment: {
            ...environment,
            if (sdkRoot != null) 'SDKROOT': sdkRoot,
          },
          includeParentEnvironment: false,
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        final header = ByteData.sublistView(File(executable).readAsBytesSync());
        expect(header.getUint32(0, Endian.little), 0xfeedfacf);
        expect(
          header.getUint32(4, Endian.little),
          Abi.current() == Abi.macosArm64 ? 0x0100000c : 0x01000007,
        );
        final loadCommands = await Process.run(
          '/usr/bin/xcrun',
          ['--sdk', 'macosx', 'otool', '-l', executable],
          environment: environment,
          includeParentEnvironment: false,
        );
        expect(
          loadCommands.exitCode,
          0,
          reason: loadCommands.stderr.toString(),
        );
        expect(
          loadCommands.stdout,
          contains(RegExp(r'platform\s+(?:MACOS|1)(?:\s|$)')),
        );
        final run = await Process.run(executable, []);
        expect(run.exitCode, 0, reason: run.stderr.toString());
        expect(run.stdout, 'native host\n');
      }
    },
    skip:
        !Platform.isMacOS ||
        Platform.environment['XCROSS_NATIVE_COMPILER_ACCEPTANCE'] != '1',
  );
}
