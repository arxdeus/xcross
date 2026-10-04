import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_build_platform.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/sdk/preserved_sdk_archive_links.dart';
import 'package:xcross/src/host/windows/sdk/materialized_sdk_archive_links.dart';
import 'package:xcross/src/shared/cli/basic/sdk_command.dart';
import 'package:xcross/src/shared/cli/basic/sdk_install.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/sdk_metadata_platform.dart';
import 'package:xcross/src/target/iphone/sdk/iphone_sdk_metadata_platform.dart';
import 'package:xcross/src/target/simulator/sdk/simulator_sdk_metadata_platform.dart';

import 'sdk_test_support.dart';

void main() {
  final sdkContext = SdkTestContext();
  tearDownAll(sdkContext.close);
  final installer = sdkContext.installer();
  final publication = SdkInstallCommand(installer);

  group('SDK dependency coherence', () {
    test('rejects a runner and repository from different host instances', () {
      final otherHost = MacOSHost();
      expect(
        () => SdkInstall(
          sdkContext.runner,
          DarwinSdkRepository(otherHost, log: sdkContext.log),
          links: PreservedSdkArchiveLinks(sdkContext.host),
          swiftInstallGuidance: 'fixture',
          swiftBuildTools: const ['swift'],
          metadataPlatforms: const [IPhoneSdkMetadataPlatform<MacOSHost>()],
        ),
        throwsArgumentError,
      );
    });

    test('freezes caller-owned tool and metadata collections', () {
      final tools = ['swift', 'swiftc'];
      final platforms = <SdkMetadataPlatformInterface<MacOSHost>>[
        const IPhoneSdkMetadataPlatform<MacOSHost>(),
        const SimulatorSdkMetadataPlatform<MacOSHost>(),
      ];
      final isolated = SdkInstall(
        sdkContext.runner,
        sdkContext.repository,
        links: PreservedSdkArchiveLinks(sdkContext.host),
        swiftInstallGuidance: 'fixture',
        swiftBuildTools: tools,
        metadataPlatforms: platforms,
      );
      tools.clear();
      platforms.clear();
      expect(isolated.swiftBuildTools, ['swift', 'swiftc']);
      expect(isolated.metadataPlatforms, hasLength(2));
      expect(
        () => isolated.swiftBuildTools.add('other'),
        throwsUnsupportedError,
      );
    });
  });

  group('SDK publication', () {
    late Directory root;

    void createValidBundle(String path) {
      for (final name in ['info.json', 'swift-sdk.json', 'toolset.json']) {
        File(p.join(path, name))
          ..createSync(recursive: true)
          ..writeAsStringSync('{}');
      }
      Directory(
        p.join(
          path,
          'Developer',
          'Platforms',
          'iPhoneOS.platform',
          'Developer',
          'SDKs',
          'iPhoneOS18.0.sdk',
          'System',
          'Library',
          'Frameworks',
        ),
      ).createSync(recursive: true);
      for (final location in [
        p.join(
          'Developer',
          'Toolchains',
          'XcodeDefault.xctoolchain',
          'usr',
          'lib',
          'swift',
          'iphoneos',
          'layouts-arm64.yaml',
        ),
        p.join(
          'Developer',
          'Runtimes',
          'XcodeDefault.xctoolchain',
          'usr',
          'bin',
          'layouts-arm64.yaml',
        ),
      ]) {
        File(p.join(path, location))
          ..createSync(recursive: true)
          ..writeAsStringSync('layout');
      }
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('xcross-sdk-publication-');
    });

    tearDown(() => root.deleteSync(recursive: true));

    for (final destination in [
      r'C:\scope\Darwin.artifactbundle',
      r'\\server\share\scope\Darwin.artifactbundle',
    ]) {
      test(
        'publishes extended-length Windows staging for $destination',
        () async {
          final paths = WindowsHost(currentDirectory: r'C:\scope').paths;
          final fileSystem = WindowsSdkStageFileSystemFixture(paths);
          final parent = paths.context.dirname(destination).toUpperCase();
          await fileSystem.directory(parent).create(recursive: true);
          final host = WindowsHost(paths: paths, fileSystem: fileSystem);
          final io = SdkCommandTestIo();
          addTearDown(io.close);
          final runner = ProcessRunner(
            host,
            log: sdkContext.log,
            stdinStream: io.input,
            stdoutSink: io.output,
            stderrSink: io.error,
          );
          final repository = DarwinSdkRepository(host, log: sdkContext.log);
          final installation = SdkInstall(
            runner,
            repository,
            links: MaterializedSdkArchiveLinks(host),
            swiftInstallGuidance: 'fixture',
            swiftBuildTools: const ['swift-build'],
            metadataPlatforms: const [IPhoneSdkMetadataPlatform<WindowsHost>()],
          );
          final command = SdkInstallCommand(installation);
          final staged = await command.createStagingSibling(destination);
          expect(staged.path, startsWith(r'\\?\'));
          await command.activateStagedSdk(staged, destination);
          expect(fileSystem.directory(destination).existsSync(), isTrue);
          expect(staged.existsSync(), isFalse);
        },
      );
    }

    test('rejects non-sibling publication before any rename', () async {
      final staged = Directory(p.join(root.path, 'other', 'staged'))
        ..createSync(recursive: true);
      File(p.join(staged.path, 'kept.txt')).writeAsStringSync('kept');
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      var publishes = 0;
      await expectLater(
        publication.activateStagedSdk(
          staged,
          destination,
          renameStaged: (directory, path) async {
            publishes++;
            return directory;
          },
        ),
        throwsArgumentError,
      );
      expect(publishes, 0);
      expect(File(p.join(staged.path, 'kept.txt')).readAsStringSync(), 'kept');
      expect(Directory(destination).existsSync(), isFalse);
    });

    test('SDK recovery writes only to its injected session log', () {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      createValidBundle('$destination.previous');
      final unrelated = SdkTestContext();
      addTearDown(unrelated.close);
      sdkContext.output.messages.clear();
      final repository = DarwinSdkRepository(
        sdkContext.host,
        log: sdkContext.log,
        installBundle: destination,
      );
      expect(repository.current(), isNotNull);
      expect(
        sdkContext.output.messages,
        contains(contains('Restored the previous Darwin Swift SDK')),
      );
      expect(unrelated.output.messages, isEmpty);
    });

    test('replaces the old SDK only after staging succeeds', () async {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      final old = Directory(destination)..createSync();
      File(p.join(old.path, 'old.txt')).writeAsStringSync('old');
      if (Platform.isWindows) {
        final deepPath = p.joinAll([
          old.path,
          ...List.filled(6, 'nested-sdk-directory-with-long-name'),
        ]);
        expect(deepPath.length, greaterThan(260));
        Directory(installer.ioPath(deepPath)).createSync(recursive: true);
        File(
          installer.ioPath(p.join(deepPath, 'header.h')),
        ).writeAsStringSync('header');
      }
      final staged = Directory(p.join(root.path, 'Darwin.staging'))
        ..createSync();
      File(p.join(staged.path, 'new.txt')).writeAsStringSync('new');

      await publication.activateStagedSdk(staged, destination);

      expect(File(p.join(destination, 'new.txt')).readAsStringSync(), 'new');
      expect(File(p.join(destination, 'old.txt')).existsSync(), isFalse);
      expect(staged.existsSync(), isFalse);
      expect(Directory('$destination.previous').existsSync(), isFalse);
    });

    test('restores the old SDK when publication fails', () async {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      final old = Directory(destination)..createSync();
      File(p.join(old.path, 'old.txt')).writeAsStringSync('old');
      final staged = Directory(p.join(root.path, 'Darwin.staging'))
        ..createSync();
      File(p.join(staged.path, 'new.txt')).writeAsStringSync('new');

      await expectLater(
        publication.activateStagedSdk(
          staged,
          destination,
          renameStaged: (_, _) async =>
              throw const FileSystemException('failed'),
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(File(p.join(destination, 'old.txt')).readAsStringSync(), 'old');
      expect(File(p.join(destination, 'new.txt')).existsSync(), isFalse);
      expect(File(p.join(staged.path, 'new.txt')).readAsStringSync(), 'new');
      expect(Directory('$destination.previous').existsSync(), isFalse);
    });

    test('rejects an incomplete staged SDK without touching the old one', () {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      final old = Directory(destination)..createSync();
      File(p.join(old.path, 'old.txt')).writeAsStringSync('old');
      final staged = Directory(p.join(root.path, 'Darwin.staging'))
        ..createSync();
      for (final name in ['info.json', 'swift-sdk.json', 'toolset.json']) {
        File(p.join(staged.path, name)).writeAsStringSync('{}');
      }
      Directory(
        p.join(
          staged.path,
          'Developer',
          'Platforms',
          'iPhoneOS.platform',
          'Developer',
          'SDKs',
          'iPhoneOS18.0.sdk',
        ),
      ).createSync(recursive: true);

      expect(
        () => publication.requireValidStagedSdk(staged.path),
        throwsA(isA<XcrossError>()),
      );
      expect(File(p.join(destination, 'old.txt')).readAsStringSync(), 'old');
    });

    test('clears a stale backup before another installation', () async {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      createValidBundle(destination);
      final backup = Directory('$destination.previous')..createSync();
      File(p.join(backup.path, 'old.txt')).writeAsStringSync('old');

      await publication.prepareExistingSdk(destination);

      expect(sdkContext.repository.isValidBundle(destination), isTrue);
      expect(backup.existsSync(), isFalse);
    });

    test('rejects a truncated simulator at the final publication gate', () {
      final destination = p.join(root.path, 'Darwin.artifactbundle');
      final staged = p.join(root.path, 'Darwin.staging');
      createValidBundle(destination);
      createValidBundle(staged);
      File(p.join(destination, 'old.txt')).writeAsStringSync('old');
      Directory(
        p.join(
          staged,
          'Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk',
        ),
      ).createSync(recursive: true);
      File(p.join(staged, 'swift-sdk.json')).writeAsStringSync(
        jsonEncode({
          'targetTriples': {
            const SimulatorBuildPlatform().swiftSdkTriple: <String, String>{},
          },
        }),
      );

      expect(
        () => publication.requireValidStagedSdk(staged),
        throwsA(isA<XcrossError>()),
      );
      expect(sdkContext.repository.isValidBundle(destination), isTrue);
      expect(File(p.join(destination, 'old.txt')).readAsStringSync(), 'old');
      expect(Directory('$destination.previous').existsSync(), isFalse);
    });
  });
}

@internal
final class WindowsSdkStageFileSystemFixture
    implements HostFileSystemInterface {
  WindowsSdkStageFileSystemFixture(this.paths);
  final HostPathsInterface paths;
  final Map<String, WindowsSdkStageDirectoryFixture> directories = {};
  @override
  Directory directory(String path) {
    final ioPath = paths.ioPath(path);
    final key = paths.pathKey(ioPath);
    return directories.putIfAbsent(
      key,
      () => WindowsSdkStageDirectoryFixture(this, ioPath),
    );
  }

  @override
  File file(String path) => throw UnsupportedError(path);
  @override
  Link link(String path) => throw UnsupportedError(path);
  @override
  void makeExecutable(String path) => throw UnsupportedError(path);
  @override
  void setPermissions(String path, int mode) => throw UnsupportedError(path);
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      throw UnsupportedError(destination);
}

@internal
final class WindowsSdkStageDirectoryFixture implements Directory {
  WindowsSdkStageDirectoryFixture(this.fileSystem, this.path);
  final WindowsSdkStageFileSystemFixture fileSystem;
  @override
  final String path;
  bool present = false;
  @override
  bool existsSync() => present;
  @override
  Future<Directory> create({bool recursive = false}) {
    present = true;
    return Future.value(this);
  }

  @override
  Future<Directory> createTemp([String? prefix]) {
    final result = fileSystem.directory(
      fileSystem.paths.context.join(path, '${prefix ?? ''}fixture'),
    );
    return result.create();
  }

  @override
  Future<Directory> rename(String newPath) async {
    present = false;
    final result = fileSystem.directory(newPath);
    await result.create();
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(invocation.memberName.toString());
}

@internal
final class SdkCommandTestIo {
  SdkCommandTestIo() {
    outputController.stream.listen((_) {});
    errorController.stream.listen((_) {});
    output = IOSink(outputController.sink);
    error = IOSink(errorController.sink);
  }

  final Stream<List<int>> input = const Stream<List<int>>.empty();
  final StreamController<List<int>> outputController =
      StreamController<List<int>>();
  final StreamController<List<int>> errorController =
      StreamController<List<int>>();
  late final IOSink output;
  late final IOSink error;

  Future<void> close() async {
    await Future.wait([output.close(), error.close()]);
  }
}
