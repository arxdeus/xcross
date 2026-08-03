import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

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
      final cBuilder = CBuilder.library(
        name: 'sysv_abi_bridge',
        assetName: 'src/adi/loader/sysv_abi_bridge.dart',
        sources: const ['src/sysv_abi_bridge.c'],
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
  final outDir = Directory.fromUri(input.outputDirectory)..createSync(recursive: true);
  final outFile = outDir.uri.resolve(os.dylibFileName('sysv_abi_bridge'));
  final source = input.packageRoot.resolve('src/sysv_abi_bridge.c');
  final cc = _resolveSystemCc();

  final args = <String>[
    '-shared',
    '-fPIC',
    '-O2',
    '-o',
    outFile.toFilePath(),
    source.toFilePath(),
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
    throw StateError('C compiler reported success but $outFile was not created');
  }

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/adi/loader/sysv_abi_bridge.dart',
      linkMode: DynamicLoadingBundled(),
      file: outFile,
    ),
  );
  output.dependencies.add(source);
}

/// Prefer absolute system compilers that are not swiftly shims.
String _resolveSystemCc() {
  for (final candidate in const [
    '/usr/bin/cc',
    '/usr/bin/gcc',
    '/usr/bin/clang',
  ]) {
    final file = File(candidate);
    if (!file.existsSync()) continue;
    final real = file.resolveSymbolicLinksSync();
    if (real.endsWith('/swiftly') || real.contains('/swiftly/')) continue;
    return candidate;
  }
  throw StateError(
    'No usable system C compiler found (/usr/bin/cc|gcc|clang). '
    'Install build-essential, or remove swiftly\'s clang shim from PATH.',
  );
}
