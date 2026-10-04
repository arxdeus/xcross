import 'dart:async';
import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:frontend_server_kit/shared/compiler/frontend_server_options.dart';
import 'package:frontend_server_kit/shared/compiler/frontend_server_session.dart';
import 'package:frontend_server_kit/shared/compiler/package_uris.dart';
import 'package:frontend_server_kit/shared/process/compiler_transport.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/mapped_frontend_file_system.dart';

void main() {
  for (final relative in [false, true]) {
    test(
      'mapped session relative=$relative creates output and owns result bytes',
      () async {
        final temp = await Directory.systemTemp.createTemp('mapped-session-');
        addTearDown(() => temp.delete(recursive: true));
        final paths = p.Context(
          style: p.Style.posix,
          current: '/frontend-${p.basename(temp.path)}',
        );
        final files = MappedFrontendFileSystem(temp.path, paths);
        final root = files.logicalRoot;
        String selected(String path) => relative ? path : '$root/$path';
        final config = selected('.dart_tool/package_config.json');
        await files.directory('$root/.dart_tool').create(recursive: true);
        await files
            .file(config)
            .writeAsString(
              '{"configVersion":2,"packages":[{"name":"mapped","rootUri":"../","packageUri":"lib/"}]}',
            );
        final result = selected('results/expression with spaces.dill');
        await files.directory('$root/results').create();
        await files.file(result).writeAsBytes([0, 1, 127, 255]);
        final factory = MappedCompilerFactory(result);
        final session = FrontendServerSession(
          FrontendServerOptions(
            dart: 'owned-dart',
            frontendServer: 'frontend_server_aot.snapshot',
            sdkRoot: '/sdk',
            packageConfig: config,
            entrypoint: selected('lib/main.dart'),
            outputDill: selected('generated/nested/app.dill'),
          ),
          processFactory: factory,
          fileSystem: files,
          paths: paths,
          packageUriLoader: PackageUriLoader(fileSystem: files, paths: paths),
          diagnostics: (_) {},
        );
        addTearDown(session.close);
        await session.spawn();
        expect(files.directory('$root/generated/nested').existsSync(), isTrue);
        expect(factory.arguments, contains(config));
        expect(await session.compile(), result);
        await session.recompile(
          invalidated: [paths.toUri('$root/lib/main.dart').toString()],
        );
        expect(
          factory.transport.commands.first,
          'compile package:mapped/main.dart\n',
        );
        expect(
          factory.transport.commands[1].split('\n')[1],
          'package:mapped/main.dart',
        );
        expect(
          await session.compileExpression(
            expression: '1 + 2',
            definitions: const [],
            definitionTypes: const [],
            typeDefinitions: const [],
            typeBounds: const [],
            typeDefaults: const [],
            libraryUri: 'package:mapped/main.dart',
            klass: null,
            method: null,
            isStatic: true,
          ),
          [0, 1, 127, 255],
        );
        await session.accept();
        await session.reject();
        await session.close();
        expect(factory.transport.closes, 1);
        expect(await files.file(result).readAsBytes(), [0, 1, 127, 255]);
        expect(
          files.lookups,
          containsAll([
            paths.absolute(config),
            selected('generated/nested'),
            result,
          ]),
        );
        expect(Directory(root).existsSync(), isFalse);
      },
    );
  }

  test('session rejects mismatched loader filesystem and path identities', () {
    final host = MacOSHost();
    const options = FrontendServerOptions(
      dart: 'owned',
      frontendServer: 'owned',
      sdkRoot: '/sdk',
      packageConfig: '/config',
      entrypoint: '/main',
      outputDill: '/out',
    );
    final factory = MappedCompilerFactory('/result');
    for (final loader in [
      PackageUriLoader(
        fileSystem: host.fileSystem,
        paths: p.Context(style: p.Style.posix),
      ),
      PackageUriLoader(
        fileSystem: MacOSHost().fileSystem,
        paths: host.paths.context,
      ),
    ]) {
      expect(
        () => FrontendServerSession(
          options,
          processFactory: factory,
          diagnostics: (_) {},
          fileSystem: host.fileSystem,
          paths: host.paths.context,
          packageUriLoader: loader,
        ),
        throwsArgumentError,
      );
    }
    expect(factory.arguments, isNull);
  });
}

@internal
final class MappedCompilerFactory implements CompilerProcessFactory {
  MappedCompilerFactory(String result)
    : transport = MappedCompilerTransport(result);
  final MappedCompilerTransport transport;
  List<String>? arguments;
  @override
  Future<CompilerTransport> start(
    String executable,
    List<String> arguments,
  ) async {
    this.arguments = arguments;
    return transport;
  }
}

@internal
final class MappedCompilerTransport implements CompilerTransport {
  MappedCompilerTransport(this.result);
  final String result;
  final lines = StreamController<String>();
  final commands = <String>[];
  int closes = 0;
  @override
  Stream<String> get output => lines.stream;
  @override
  Stream<String> get diagnostics => const Stream.empty();
  @override
  Future<int> get exitCode async => 0;
  @override
  Future<void> send(String command) async {
    commands.add(command);
    if (command.startsWith('compile ') ||
        command.startsWith('recompile ') ||
        command.startsWith('compile-expression ')) {
      lines.add('result boundary');
      lines.add('boundary');
      lines.add('boundary $result 0');
    }
  }

  @override
  Future<void> close() async {
    closes++;
    await lines.close();
  }
}
