import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Asset id of the code asset, which must stay equal to the path of the
/// library holding the `@Native` externals: that is the id those lookups
/// default to, and a mismatch only shows up at runtime as "no asset with id".
const _assetName = 'src/host/shared/adi/loader/internal/sysv_abi_bridge.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final logger = Logger('')
      ..level = Level.INFO
      ..onRecord.listen((record) => print(record.message));

    // On Linux, PATH often puts swiftly's `clang` shim first. native_toolchain_c
    // resolveSymbolicLinks that shim to the `swiftly` binary and then invokes
    // it as the C compiler (exit 64, no .so) while still emitting a CodeAsset —
    // dart build then fails with "file does not exist". Compile with a real
    // system cc ourselves on non-Windows hosts.
    if (input.config.code.targetOS == OS.windows) {
      if (input.config.code.targetArchitecture != Architecture.x64) {
        throw UnsupportedError('Windows ADI requires x64.');
      }
      final cBuilder = CBuilder.library(
        name: 'sysv_abi_bridge',
        assetName: _assetName,
        sources: const ['src/host/shared/adi/sysv_abi_bridge.c'],
      );
      await cBuilder.run(input: input, output: output, logger: logger);
      return;
    }

    await _buildWithSystemCc(input: input, output: output, logger: logger);
  });
}

Future<void> _buildWithSystemCc({
  required BuildInput input,
  required BuildOutputBuilder output,
  required Logger logger,
}) async {
  final os = input.config.code.targetOS;
  final outDir = Directory.fromUri(input.outputDirectory)
    ..createSync(recursive: true);
  final outFile = outDir.uri.resolve(os.dylibFileName('sysv_abi_bridge'));
  final source = input.packageRoot.resolve(
    'src/host/shared/adi/sysv_abi_bridge.c',
  );
  final posixSource = input.packageRoot.resolve(
    'src/host/shared/adi/posix_bridge.c',
  );
  final targetFlags = systemCompilerFlags(
    targetOS: os,
    targetArchitecture: input.config.code.targetArchitecture,
    hostOS: OS.current,
    hostArchitecture: Architecture.current,
  );
  final macOSCompiler = os == OS.macOS ? await resolveMacOSCompiler() : null;
  final cc = macOSCompiler?.executable ?? _resolveSystemCc();

  final args = <String>[
    ...targetFlags,
    if (macOSCompiler != null) ...macOSCompiler.flags,
    '-shared',
    '-fPIC',
    '-O2',
    '-o',
    outFile.toFilePath(),
    source.toFilePath(),
    posixSource.toFilePath(),
  ];
  logger.info('Running `$cc ${args.join(' ')}`.');
  final result = await Process.run(cc, args);
  if (result.stdout.toString().trim().isNotEmpty) {
    logger.info(result.stdout.toString());
  }
  if (result.stderr.toString().trim().isNotEmpty) {
    logger.severe(result.stderr.toString());
  }
  if (result.exitCode != 0) {
    throw ProcessException(cc, args, result.stderr.toString(), result.exitCode);
  }
  if (!File.fromUri(outFile).existsSync()) {
    throw StateError(
      'C compiler reported success but $outFile was not created',
    );
  }

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _assetName,
      linkMode: DynamicLoadingBundled(),
      file: outFile,
    ),
  );
  output.dependencies.add(source);
  output.dependencies.add(posixSource);
}

Future<({String executable, List<String> flags})> resolveMacOSCompiler({
  Map<String, String>? environment,
  Future<ProcessResult> Function(
        String,
        List<String>, {
        required bool includeParentEnvironment,
        Map<String, String>? environment,
      })
      runProcess =
      Process.run,
}) async {
  final nativeEnvironment = Map<String, String>.of(
    environment ?? Platform.environment,
  )..remove('SDKROOT');
  Future<String> resolve(List<String> arguments) async {
    final args = ['--sdk', 'macosx', ...arguments];
    final result = await runProcess(
      '/usr/bin/xcrun',
      args,
      environment: nativeEnvironment,
      includeParentEnvironment: false,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        '/usr/bin/xcrun',
        args,
        result.stderr.toString(),
        result.exitCode,
      );
    }
    final path = result.stdout.toString().trim();
    if (path.isEmpty) throw StateError('xcrun returned an empty native path.');
    return path;
  }

  return (
    executable: await resolve(['--find', 'clang']),
    flags: [
      '-isysroot',
      await resolve(['--show-sdk-path']),
    ],
  );
}

/// Prefer absolute system compilers that are not swiftly shims.
String _resolveSystemCc() {
  // Hardcoded /usr/bin paths don't exist on all Linux distros (e.g. NixOS
  // has no /usr/bin at all), so search PATH generically instead, filtering
  // out the swiftly clang shim by the same symlink check as before.
  final pathEnv = Platform.environment['PATH'] ?? '';
  final dirs = pathEnv.split(':');

  for (final name in const ['cc', 'gcc', 'clang']) {
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      final file = File('$dir/$name');
      if (!file.existsSync()) continue;
      final real = file.resolveSymbolicLinksSync();
      if (real.endsWith('/swiftly') || real.contains('/swiftly/')) continue;
      return file.path;
    }
  }
  throw StateError(
    'No usable system C compiler found (cc|gcc|clang) on PATH. '
    "Install build-essential, or remove swiftly's clang shim from PATH.",
  );
}

List<String> systemCompilerFlags({
  required OS targetOS,
  required Architecture targetArchitecture,
  required OS hostOS,
  required Architecture hostArchitecture,
}) {
  if (targetOS != hostOS || (targetOS != OS.macOS && targetOS != OS.linux)) {
    throw UnsupportedError(
      'ADI native bridge requires a matching Linux or macOS build host.',
    );
  }
  if (targetArchitecture != Architecture.x64 &&
      targetArchitecture != Architecture.arm64) {
    throw UnsupportedError(
      'Unsupported ADI target architecture: $targetArchitecture',
    );
  }
  if (targetOS == OS.linux && targetArchitecture != hostArchitecture) {
    throw UnsupportedError(
      'ADI Linux cross-compilation requires a target toolchain.',
    );
  }
  return [
    if (targetOS == OS.macOS) ...[
      '-arch',
      if (targetArchitecture == Architecture.arm64) 'arm64' else 'x86_64',
    ],
  ];
}
