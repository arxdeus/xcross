import 'dart:io';

import 'package:meta/meta.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/swiftpm/preview_macro_compiler.dart';

import 'swiftpm_test_context.dart';

@internal
final class RecordingSwiftPmNativeCompiler implements SwiftPmNativeCompiler {
  int calls = 0;
  String revision = 'first';
  bool fail = false;
  final arguments = <List<String>>[];
  @override
  Future<Map<String, Object>> identity(String executable) async => {
    'path': executable,
    'revision': revision,
  };
  @override
  Future<void> compile(String executable, List<String> args) async {
    calls++;
    arguments.add(List.of(args));
    File(args[args.indexOf('-o') + 1]).writeAsStringSync('native-$calls');
    if (fail) throw StateError('compiler failed');
  }
}

void main() {
  final runtime = testSwiftPmRuntime();
  late Directory root;
  late RecordingSwiftPmNativeCompiler native;
  late SwiftPmPreviewMacroCompiler compiler;
  setUp(() {
    root = Directory.systemTemp.createTempSync('xcross-preview-cache-');
    native = RecordingSwiftPmNativeCompiler();
    compiler = SwiftPmPreviewMacroCompiler(
      host: runtime.host,
      hostTools: runtime.tools.hostTools,
      filesystem: runtime.filesystem,
      compiler: native,
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('reuses unchanged source and native compiler identity', () async {
    final first = await compiler.write(
      outputDir: root.path,
      cCompilerPath: '/native/clang',
      source: 'source',
    );
    expect(
      await compiler.write(
        outputDir: root.path,
        cCompilerPath: '/native/clang',
        source: 'source',
      ),
      first,
    );
    expect(native.calls, 1);
  });

  test(
    'source, compiler arguments and compiler identity invalidate cache',
    () async {
      await compiler.write(
        outputDir: root.path,
        cCompilerPath: '/native/clang',
        source: 'first',
      );
      await compiler.write(
        outputDir: root.path,
        cCompilerPath: '/native/clang',
        source: 'second',
      );
      await compiler.write(
        outputDir: root.path,
        cCompilerPath: '/native/clang',
        source: 'second',
        cCompilerArguments: const ['--sdk', 'macosx'],
      );
      native.revision = 'replacement';
      await compiler.write(
        outputDir: root.path,
        cCompilerPath: '/native/clang',
        source: 'second',
        cCompilerArguments: const ['--sdk', 'macosx'],
      );
      expect(native.calls, 4);
      expect(native.arguments.last, isNot(contains('iphoneos')));
      expect(native.arguments.last, isNot(contains('arm64-apple-ios')));
    },
  );

  test(
    'failed compilation never publishes or reuses a partial executable',
    () async {
      native.fail = true;
      await expectLater(
        compiler.write(
          outputDir: root.path,
          cCompilerPath: '/native/clang',
          source: 'source',
        ),
        throwsStateError,
      );
      final executable = File('${root.path}/.xcross/preview-macro-stub/stub');
      expect(executable.existsSync(), isFalse);
      native.fail = false;
      await compiler.write(
        outputDir: root.path,
        cCompilerPath: '/native/clang',
        source: 'source',
      );
      expect(native.calls, 2);
      expect(executable.readAsStringSync(), 'native-2');
    },
  );

  test('mutated cached executable is rebuilt', () async {
    final path = await compiler.write(
      outputDir: root.path,
      cCompilerPath: '/native/clang',
      source: 'source',
    );
    File(path).writeAsStringSync('mutated');
    await compiler.write(
      outputDir: root.path,
      cCompilerPath: '/native/clang',
      source: 'source',
    );
    expect(native.calls, 2);
  });
}
