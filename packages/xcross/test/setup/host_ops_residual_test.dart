import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:crypto/crypto.dart';
import 'package:darwin_sdk_kit/host/shared/darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/linux/update/linux_update_policy.dart';
import 'package:xcross/src/host/shared/setup/posix_setup_script.dart';
import 'package:xcross/src/shared/cli/basic/internal/clang_requirement.dart';
import 'package:xcross/src/shared/cli/basic/internal/swift_requirement.dart';
import 'package:xcross/src/shared/cli/shared/ipa_packager.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/sdk_directory_copy.dart';
import 'package:xcross/src/shared/setup/setup_script.dart';
import 'package:xcross/src/shared/setup/setup_script_policy.dart';
import 'package:xcross/src/shared/update/git_ref_source_bundle_builder.dart';
import 'package:xcross/src/shared/update/git_update_ref_resolver.dart';
import 'package:xcross/src/shared/update/install_layout.dart';
import 'package:xcross/src/shared/update/internal/release_payload.dart';
import 'package:xcross/src/shared/update/self_update.dart';
import 'package:xcross/src/shared/xcrun/cross_xcrun.dart';

import '../host_operations_fixtures.dart';
import 'host_ops_residual_fixtures.dart';

void main() {
  late Directory backing;
  late ResidualPaths paths;
  late ResidualFileSystem files;
  late ResidualHost host;
  late LinuxHostInterface base;
  late ResidualProcesses processes;

  setUp(() async {
    base = LinuxHost(architecture: 'x64');
    backing = Directory(
      await (await Directory.systemTemp.createTemp(
        'host-ops-residual-',
      )).resolveSymbolicLinks(),
    );
    paths = ResidualPaths(
      '/selected-${backing.uri.pathSegments.lastWhere((part) => part.isNotEmpty)}',
    );
    files = ResidualFileSystem(paths.root, backing);
    processes = ResidualProcesses(
      (_, _, _) async => throw StateError('unexpected process'),
    );
    host = ResidualHost(
      base: base,
      fileSystem: files,
      paths: paths,
      processes: processes,
    );
    await files.directory(paths.temporaryRoot).create();
    files.lookups.clear();
  });

  tearDown(() async {
    expect(Directory(paths.root).existsSync(), isFalse);
    await backing.delete(recursive: true);
  });

  String path(String name) => paths.context.join(paths.root, name);

  Future<void> write(String name, String value) async {
    final file = files.file(path(name));
    await file.parent.create(recursive: true);
    await file.writeAsString(value);
  }

  test(
    'residual host retains the explicitly composed base and selected ports',
    () {
      expect(host.base, same(base));
      expect(host.environment, same(base.environment));
      expect(host.architecture, base.architecture);
      expect(host.name, base.name);
      expect(host.fileSystem, same(files));
      expect(host.paths, same(paths));
      expect(host.processes, same(processes));
    },
  );

  test('mapped clang discovers versioned pair in selected namespace', () async {
    await write('tools/clang-22', 'clang');
    await write('tools/clang++-22', 'clang++');
    processes = ResidualProcesses((_, args, _) async {
      expect(args, ['--version']);
      return ResidualChild(output: 'clang version 22.0.1');
    });
    host = ResidualHost(
      base: base,
      fileSystem: files,
      paths: paths,
      processes: processes,
    );
    final runner = residualRunner(
      host,
      lookup: (name, dirs) async {
        expect(dirs, [path('tools')]);
        final candidate = path('tools/$name');
        return files.file(candidate).existsSync() ? candidate : null;
      },
    );
    files.lookups.clear();
    expect(
      await ClangRequirement(runner).resolve(directories: [path('tools')]),
      path('tools/clang-22'),
    );
    expect(files.lookups, contains(path('tools')));
    expect(files.lookups, contains(path('tools/clang++-22')));
  });

  test(
    'mapped swift resolves real symlink before checking actual sibling',
    () async {
      await write('actual/swift', 'swift');
      await write('actual/clang', 'clang');
      await files.directory(path('alias')).create();
      await files.link(path('alias/swift')).create('../actual/swift');
      files.lookups.clear();
      final service = SwiftRequirement(residualRunner(host));
      await service.requireSiblingClang(path('alias/swift'));
      final actualClang = files.file(path('actual/clang'));
      expect(files.lookups, contains(path('alias/swift')));
      expect(files.lookups, contains(actualClang.path));
      await actualClang.delete();
      await write('alias/clang', 'wrong installation');
      await expectLater(
        service.requireSiblingClang(path('alias/swift')),
        throwsA(isA<XcrossError>()),
      );
    },
  );

  test(
    'mapped ipa returns logical output and dereferences nested links',
    () async {
      await write('MyApp.app/nested/data', 'payload');
      await files.link(path('MyApp.app/alias')).create('nested/data');
      await write('MyApp.ipa', 'stale');
      files.lookups.clear();
      final result = await IpaPackager(host: host).package(path('MyApp.app'));
      expect(result, path('MyApp.ipa'));
      expect(files.lookups, contains(path('MyApp.app')));
      expect(files.lookups, contains(path('MyApp.ipa')));
      final archive = ZipDecoder().decodeBytes(
        await files.file(result).readAsBytes(),
      );
      expect(archive.files.map((entry) => entry.name).toSet(), {
        'Payload/MyApp.app/nested/data',
        'Payload/MyApp.app/alias',
      });
      for (final entry in archive.files) {
        expect(utf8.decode(entry.content), 'payload');
      }
    },
  );

  test(
    'mapped setup temporary files use selected FS and leave atomic cache',
    () async {
      var downloads = 0;
      final manager = SetupScriptManager(
        host: host,
        runner: residualRunner(host),
        policy: PosixSetupScript(host),
        createHttpClient: () => throw StateError('unexpected HTTP'),
        source: 'https://fixture.invalid/setup.sh',
        download: (_) async {
          downloads++;
          return utf8.encode('echo selected');
        },
      );
      final script = await manager.refresh();
      expect(await script!.readAsString(), 'echo selected');
      expect((await manager.resolve())!.path, script.path);
      expect(downloads, 1);
      expect(files.lookups.where((value) => value.endsWith('.tmp')).length, 2);
      expect(
        backing
            .listSync(recursive: true)
            .where((entry) => entry.path.endsWith('.tmp')),
        isEmpty,
      );
      final digest = sha256.convert(utf8.encode('echo selected')).toString();
      expect(
        files.lookups,
        contains(
          paths.context.join(paths.cacheRoot, 'setup-scripts', '$digest.sh'),
        ),
      );
    },
  );

  test(
    'mapped sdk copy materializes nested destinations and follows links',
    () async {
      await write('sdk/nested/value', 'sdk bytes');
      await files.link(path('sdk/alias')).create('nested/value');
      await files.link(path('sdk/directory')).create('nested');
      files.lookups.clear();
      await SdkDirectoryCopy(host).copy(path('sdk'), path('copied'));
      expect(
        await files.file(path('copied/nested/value')).readAsString(),
        'sdk bytes',
      );
      expect(
        await files.file(path('copied/alias')).readAsString(),
        'sdk bytes',
      );
      expect(
        await files.file(path('copied/directory/value')).readAsString(),
        'sdk bytes',
      );
      expect(await files.link(path('sdk/alias')).target(), 'nested/value');
      expect(
        await files.file(path('sdk/nested/value')).readAsString(),
        'sdk bytes',
      );
      expect(files.lookups, contains(path('copied/nested/value')));
    },
  );

  test(
    'mapped xcrun sidecar settings and shim retain logical responses',
    () async {
      await write('tools/xcrun.sdk', path('iPhoneOS.sdk'));
      await write('tools/clang', 'compiler');
      await write('iPhoneOS.sdk/SDKSettings.json', '{"Version":"26.5"}');
      files.lookups.clear();
      final probe = CrossXcrunProbe(host);
      expect(
        probe.response(['--show-sdk-path'], executable: path('tools/xcrun')),
        path('iPhoneOS.sdk'),
      );
      expect(
        probe.response(['--show-sdk-version'], executable: path('tools/xcrun')),
        '26.5',
      );
      expect(
        probe.findTool(['--find', 'clang'], executable: path('tools/xcrun')),
        path('tools/clang'),
      );
      expect(files.lookups, contains(path('tools/xcrun.sdk')));
      expect(files.lookups, contains(path('iPhoneOS.sdk/SDKSettings.json')));
      expect(files.lookups, contains(path('tools/clang')));
    },
  );

  test(
    'mapped xcrun fallback discovers compiler sibling through selected FS',
    () async {
      await write('tools/xcrun.sdk', path('iPhoneOS26.5.sdk'));
      await write('tools/clang', 'compiler');
      await write('tools/llvm-ar', 'archiver');
      processes = ResidualProcesses((tool, args, _) async {
        expect(tool, path('tools/clang'));
        expect(args, contains('-###'));
        return ResidualChild();
      });
      host = ResidualHost(
        base: base,
        fileSystem: files,
        paths: paths,
        processes: processes,
      );
      final runner = residualRunner(
        host,
        lookup: (name, _) async => name == 'clang' ? path('tools/clang') : null,
      );
      final output = fixtureSink();
      final command = XcrunSdkCommand(
        runner: runner,
        output: output,
        errors: fixtureSink(),
        repository: DarwinSdkRepository(
          host,
          log: runner.log,
          installBundle: path('missing-sdk'),
        ),
        toolchain: DarwinToolchainResolver(
          runner,
          ResidualToolchainLocations(path('tools')),
        ),
        executable: path('tools/xcrun'),
        normalizeExecutable: (value) => value,
        target: const IPhoneBuildPlatform(),
      );
      files.lookups.clear();
      expect(
        await command.run(['--find', 'ar'], sdk: DarwinSdk(path('sdk'))),
        0,
      );
      expect(output.buffer.toString(), '${path('tools/llvm-ar')}\n');
      expect(files.lookups, contains(path('tools/llvm-ar')));
    },
  );

  test(
    'mapped setup failed promotion leaves prior cache and removes temporary',
    () async {
      SetupScriptManager manager(SetupScriptPolicy policy, String contents) =>
          SetupScriptManager(
            host: host,
            runner: residualRunner(host),
            policy: policy,
            createHttpClient: () => throw StateError('unexpected HTTP'),
            source: 'https://fixture.invalid/setup.sh',
            download: (_) async => utf8.encode(contents),
          );
      final policy = PosixSetupScript(host);
      final original = await manager(policy, 'old script').refresh();
      files.lookups.clear();
      await expectLater(
        manager(ResidualFailingSetupPolicy(policy), 'new script').refresh(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await original!.readAsString(), 'old script');
      expect((await manager(policy, 'unused').resolve())!.path, original.path);
      expect(
        files.lookups.where((value) => value.endsWith('.tmp')),
        isNotEmpty,
      );
      expect(
        backing
            .listSync(recursive: true)
            .where((entry) => entry.path.endsWith('.tmp')),
        isEmpty,
      );
    },
  );

  test(
    'mapped source build failure removes selected staging without callback',
    () async {
      processes = ResidualProcesses(
        (_, args, _) async => args.first == 'clone'
            ? ResidualChild()
            : ResidualChild(code: 1, errors: 'fixture fetch failure'),
      );
      host = ResidualHost(
        base: base,
        fileSystem: files,
        paths: ResidualMappedPaths(paths.root, files),
        processes: processes,
      );
      final builder = GitRefSourceBundleBuilder(
        runner: residualRunner(host),
        acceptDartLauncher: (_) => true,
        resolveDartExecutable: () async => '/fixture/dart',
      );
      await expectLater(
        builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'fixture',
            fetchRef: 'refs/heads/fixture',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_, _) async => throw StateError('unexpected bundle'),
        ),
        throwsA(isA<XcrossError>()),
      );
      expect(files.directory(paths.temporaryRoot).listSync(), isEmpty);
    },
  );

  test(
    'mapped source builder keeps logical lookup and effective process paths then cleans',
    () async {
      final calls = <(String, List<String>, String?)>[];
      processes = ResidualProcesses((executable, args, workingDirectory) async {
        calls.add((executable, args, workingDirectory));
        if (args.first == 'clone') {
          expect(args.last.startsWith(backing.path), isTrue);
          await Directory(args.last).create(recursive: true);
        }
        if (args.contains('tool/build_xcross.dart')) {
          final bundlePath = paths.context.join(
            workingDirectory!,
            'build',
            'cli',
            'linux_x64',
            'bundle',
          );
          await files
              .directory(paths.context.join(bundlePath, 'bin'))
              .create(recursive: true);
          await files.directory(paths.context.join(bundlePath, 'lib')).create();
        }
        return ResidualChild();
      });
      host = ResidualHost(
        base: base,
        fileSystem: files,
        paths: ResidualMappedPaths(paths.root, files),
        processes: processes,
      );
      final builder = GitRefSourceBundleBuilder(
        runner: residualRunner(host),
        acceptDartLauncher: (_) => true,
        resolveDartExecutable: () async => '/fixture/dart',
      );
      Directory? observed;
      await builder.build<void>(
        ref: const GitUpdateRef(
          kind: GitUpdateRefKind.branch,
          displayName: 'fixture',
          fetchRef: 'refs/heads/fixture',
          commitSha: '1234567890abcdef1234567890abcdef12345678',
        ),
        onBundle: (bundle, _) async {
          observed = bundle;
          expect(bundle.existsSync(), isTrue);
          expect(bundle.path.startsWith(backing.path), isTrue);
        },
      );
      expect(observed!.existsSync(), isFalse);
      expect(calls, hasLength(5));
      for (final call in calls.skip(1)) {
        expect(call.$3!.startsWith(backing.path), isTrue);
      }
      expect(
        files.lookups.where(
          (value) =>
              value.startsWith(paths.temporaryRoot) &&
              value.endsWith('/bundle'),
        ),
        isNotEmpty,
      );
    },
  );

  test(
    'mapped release extraction selects namespace and rejects unsafe payload',
    () async {
      final archive = Archive()
        ..add(ArchiveFile.string('bin/xcross', 'binary'))
        ..add(ArchiveFile.string('lib/runtime.so', 'library'));
      final extractor = ReleasePayload(host);
      await extractor.extract(
        bytes: ZipEncoder().encodeBytes(archive),
        asset: 'fixture.zip',
        destination: path('payload'),
        executableName: 'xcross',
      );
      expect(
        await files.file(path('payload/bin/xcross')).readAsString(),
        'binary',
      );
      expect(files.lookups, contains(path('payload/lib/runtime.so')));
      archive.add(ArchiveFile.string('../escape', 'unsafe'));
      await expectLater(
        extractor.extract(
          bytes: ZipEncoder().encodeBytes(archive),
          asset: 'fixture.zip',
          destination: path('rejected'),
          executableName: 'xcross',
        ),
        throwsA(isA<XcrossError>()),
      );
      expect(files.file(path('escape')).existsSync(), isFalse);
    },
  );

  test(
    'mapped self update applies offline payload and removes staging',
    () async {
      final archive = Archive()
        ..add(ArchiveFile.string('bin/xcross', 'new binary'))
        ..add(ArchiveFile.string('bin/xcrun', 'new shim'))
        ..add(ArchiveFile.string('lib/runtime.so', 'new library'));
      final bytes = const GZipEncoder().encodeBytes(
        TarEncoder().encodeBytes(archive),
      );
      final manifest = utf8.encode(
        '${sha256.convert(bytes)}  xcross-linux-x64.tar.gz\n',
      );
      await write('install/bin/xcross', 'old binary');
      await write('install/bin/xcrun', 'old shim');
      await write('install/lib/runtime.so', 'old library');
      processes = ResidualProcesses((_, args, _) async {
        expect(args, ['--version']);
        return ResidualChild(output: 'xcross 1.2.3\n');
      });
      host = ResidualHost(
        base: base,
        fileSystem: files,
        paths: paths,
        processes: processes,
      );
      final runner = residualRunner(host);
      final updater = SelfUpdate(
        host: host,
        runner: runner,
        policy: LinuxUpdatePolicy(host, runner, FixturePrivileges()),
        downloader: Downloader(
          log: runner.log,
          createClient: () => ResidualHttpClient(bytes, manifest),
        ),
      );
      await updater.apply(
        layout: InstallLayout(
          host: host,
          binaryPath: path('install/bin/xcross'),
          binDir: path('install/bin'),
          libDir: path('install/lib'),
        ),
        tag: 'v1.2.3',
      );
      expect(
        await files.file(path('install/bin/xcross')).readAsString(),
        'new binary',
      );
      expect(
        await files.file(path('install/lib/runtime.so')).readAsString(),
        'new library',
      );
      expect(files.directory(paths.temporaryRoot).listSync(), isEmpty);
      expect(
        files.lookups.where(
          (value) =>
              value.startsWith(paths.temporaryRoot) &&
              value.endsWith('xcross-linux-x64.tar.gz'),
        ),
        isNotEmpty,
      );
    },
  );

  test(
    'mapped stale cleanup preserves fresh rollback and unrelated files',
    () async {
      for (final name in [
        '.xcross.old-999',
        '.runtime.so.old-999-failed',
        '.xcross.new-999',
        'runtime.so.old-2024',
        '.xcross.old-123',
      ]) {
        await write('install/bin/$name', name);
      }
      await files.directory(path('install/lib')).create(recursive: true);
      for (final name in [
        '.xcross.old-999',
        '.runtime.so.old-999-failed',
        '.xcross.new-999',
        'runtime.so.old-2024',
      ]) {
        files
            .file(path('install/bin/$name'))
            .setLastModifiedSync(
              DateTime.now().subtract(const Duration(hours: 1)),
            );
      }
      final runner = residualRunner(host);
      final updater = SelfUpdate(
        host: host,
        runner: runner,
        policy: LinuxUpdatePolicy(host, runner, FixturePrivileges()),
        downloader: Downloader(
          log: runner.log,
          createClient: () => throw StateError('unexpected HTTP'),
        ),
      );
      files.lookups.clear();
      updater.sweepStaleBackups(
        InstallLayout(
          host: host,
          binaryPath: path('install/bin/xcross'),
          binDir: path('install/bin'),
          libDir: path('install/lib'),
        ),
      );
      expect(
        files.lookups,
        containsAll([path('install/bin'), path('install/lib')]),
      );
      expect(
        files
            .directory(path('install/bin'))
            .listSync()
            .map((entry) => paths.context.basename(entry.path))
            .toSet(),
        {'runtime.so.old-2024', '.xcross.old-123'},
      );
    },
  );

  test(
    'mapped self update rolls back every installed artifact on verification failure',
    () async {
      for (final name in ['bin/xcross', 'bin/xcrun', 'lib/runtime.so']) {
        await write('install/$name', 'old $name');
        await write('bundle/$name', 'new $name');
      }
      processes = ResidualProcesses((_, _, _) async => ResidualChild(code: 1));
      host = ResidualHost(
        base: base,
        fileSystem: files,
        paths: paths,
        processes: processes,
      );
      final runner = residualRunner(host);
      final updater = SelfUpdate(
        host: host,
        runner: runner,
        policy: LinuxUpdatePolicy(host, runner, FixturePrivileges()),
        downloader: Downloader(
          log: runner.log,
          createClient: () => throw StateError('unexpected HTTP'),
        ),
      );
      await expectLater(
        updater.installBundle(
          bundleRoot: files.directory(path('bundle')),
          layout: InstallLayout(
            host: host,
            binaryPath: path('install/bin/xcross'),
            binDir: path('install/bin'),
            libDir: path('install/lib'),
          ),
          label: 'fixture',
        ),
        throwsA(isA<XcrossError>()),
      );
      for (final name in ['bin/xcross', 'bin/xcrun', 'lib/runtime.so']) {
        expect(
          await files.file(path('install/$name')).readAsString(),
          'old $name',
        );
        expect(
          await files.file(path('bundle/$name')).readAsString(),
          'new $name',
        );
      }
      expect(files.lookups, contains(files.directory(path('bundle/lib')).path));
      final parked = backing
          .listSync(recursive: true)
          .whereType<File>()
          .where((entry) => entry.path.contains('.old-'))
          .toList();
      expect(parked, hasLength(3));
      for (final entry in parked) {
        expect(entry.path.endsWith('-failed'), isTrue);
        expect(await entry.readAsString(), startsWith('new '));
      }
      expect(
        backing
            .listSync(recursive: true)
            .where((entry) => entry.path.contains('.new-')),
        isEmpty,
      );
    },
  );
}

@internal
final class ResidualMappedPaths implements HostPathsInterface {
  @override
  String toolNameKey(String name) => base.toolNameKey(name);

  ResidualMappedPaths(String root, this.files) : base = ResidualPaths(root);
  final ResidualPaths base;
  final ResidualFileSystem files;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  String ioPath(String path) =>
      path.startsWith(base.root) ? files.physical(path) : path;
  @override
  p.Context get context => base.context;
  @override
  String get temporaryRoot => base.temporaryRoot;
  @override
  String get cacheRoot => base.cacheRoot;
  @override
  String get configRoot => base.configRoot;
  @override
  String executableName(String name, {String extension = '.exe'}) =>
      base.executableName(name, extension: extension);
  @override
  String pathKey(String path) => base.pathKey(path);
}

@internal
final class ResidualHttpClient implements HttpClient {
  ResidualHttpClient(this.archive, this.manifest);
  final List<int> archive;
  final List<int> manifest;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => ResidualHttpRequest(
    url.path.endsWith('SHA256SUMS.txt') ? manifest : archive,
  );
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@internal
final class ResidualHttpRequest implements HttpClientRequest {
  ResidualHttpRequest(this.bytes);
  final List<int> bytes;
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 10;
  @override
  Future<HttpClientResponse> close() async => ResidualHttpResponse(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@internal
final class ResidualHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  ResidualHttpResponse(this.bytes);
  final List<int> bytes;
  @override
  int get contentLength => bytes.length;
  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@internal
final class ResidualToolchainLocations
    implements DarwinToolchainLocationsInterface {
  ResidualToolchainLocations(this.directory);
  final String directory;
  @override
  List<String> llvmToolDirectories() => [directory];
  @override
  String get linkerInstallationHint => 'fixture linker';
  @override
  String get clangInstallationHint => 'fixture compiler';
}

@internal
final class ResidualFailingSetupPolicy implements SetupScriptPolicy {
  ResidualFailingSetupPolicy(this.base);
  final SetupScriptPolicy base;
  @override
  String? get defaultSource => base.defaultSource;
  @override
  File cachedFile(String digest) => base.cachedFile(digest);
  @override
  File cachePointer(String digest) => base.cachePointer(digest);
  @override
  Future<({String executable, List<String> arguments})> invocation(
    String path,
  ) => base.invocation(path);
  @override
  void replace(File temporary, File destination) =>
      throw FileSystemException('fixture promotion failure', destination.path);
}
