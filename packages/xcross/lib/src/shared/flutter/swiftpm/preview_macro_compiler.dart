import 'dart:convert';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/build/preview_macro_stub_source.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';

@internal
abstract interface class SwiftPmNativeCompiler {
  Future<Map<String, Object>> identity(String executable);
  Future<void> compile(String executable, List<String> arguments);
}

@internal
final class ProcessSwiftPmNativeCompiler<T extends PlatformHostInterface>
    implements SwiftPmNativeCompiler {
  ProcessSwiftPmNativeCompiler(this.runner);
  final ProcessRunner<T> runner;
  @override
  Future<Map<String, Object>> identity(String executable) async {
    final located = runner.host.paths.context.isAbsolute(executable)
        ? executable
        : await runner.locateTool(executable);
    final file = runner.host.fileSystem.file(located);
    return {
      'path': await file.resolveSymbolicLinks(),
      'digest': (await sha256.bind(file.openRead()).first).toString(),
    };
  }

  @override
  Future<void> compile(String executable, List<String> arguments) => runner
      .runChecked(executable, arguments, label: 'compile preview macro stub');
}

@internal
final class SwiftPmPreviewMacroCompiler<T extends PlatformHostInterface> {
  SwiftPmPreviewMacroCompiler({
    required this.host,
    required this.filesystem,
    required this.compiler,
  });
  final T host;
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmNativeCompiler compiler;

  Future<String> write({
    required String outputDir,
    required String cCompilerPath,
    List<String> cCompilerArguments = const [],
    String source = previewMacroStubSource,
  }) async {
    final paths = host.paths.context;
    final root = host.fileSystem.directory(
      paths.join(outputDir, '.xcross', 'preview-macro-stub'),
    );
    await root.create(recursive: true);
    final sourcePath = paths.join(root.path, 'stub.c');
    await filesystem.writeStable(sourcePath, source);
    final executable = host.fileSystem.file(
      paths.join(root.path, host.paths.executableName('stub')),
    );
    final stamp = host.fileSystem.file(paths.join(root.path, 'identity.json'));
    final identity = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'source': source,
              'compiler': await compiler.identity(cCompilerPath),
              'arguments': cCompilerArguments,
              'host': host.name,
              'architecture': host.architecture,
            }),
          ),
        )
        .toString();
    if (executable.existsSync() && stamp.existsSync()) {
      try {
        final recorded = jsonDecode(await stamp.readAsString());
        if (recorded is Map &&
            recorded['identity'] == identity &&
            recorded['digest'] ==
                (await sha256.bind(executable.openRead()).first).toString()) {
          return executable.path;
        }
      } on Object {
        if (stamp.existsSync()) await stamp.delete();
      }
    }
    final staging = await root.createTemp('compile-');
    try {
      final output = host.fileSystem.file(
        paths.join(staging.path, host.paths.executableName('stub')),
      );
      await compiler.compile(cCompilerPath, [
        ...cCompilerArguments,
        '-O2',
        '-o',
        output.path,
        sourcePath,
      ]);
      if (!output.existsSync() || await output.length() == 0) {
        throw StateError(
          'Native preview compiler did not produce an executable',
        );
      }
      final digest = (await sha256.bind(output.openRead()).first).toString();
      if (executable.existsSync()) await executable.delete();
      await output.rename(executable.path);
      await filesystem.writeStable(
        stamp.path,
        jsonEncode({'identity': identity, 'digest': digest}),
      );
      return executable.path;
    } finally {
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }
}
