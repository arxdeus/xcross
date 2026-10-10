import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_paths.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/sdk/preserved_sdk_archive_links.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/sdk_archive_extraction.dart';
import 'package:xcross/src/shared/sdk/sdk_install_constants.dart';
import 'package:xcross/src/shared/sdk/sdk_swift_toolchain.dart';

import 'sdk_test_support.dart';

void main() {
  late Directory temporary;
  late MappedSdkInspectionFileSystem files;
  late SdkTestContext context;
  late ProcessRunner<MacOSHost> runner;
  final paths = p.Context(style: p.Style.posix);

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'sdk-selected-inspection-',
    );
    files = MappedSdkInspectionFileSystem(
      logicalRoot: '/virtual-${paths.basename(temporary.path)}',
      backingRoot: temporary.path,
      paths: paths,
    );
    context = SdkTestContext();
    final host = MacOSHost(
      fileSystem: files,
      paths: PosixPaths(context: paths),
    );
    runner = ProcessRunner(
      host,
      log: context.log,
      stdinStream: const Stream<List<int>>.empty(),
      stdoutSink: context.stdoutSink,
      stderrSink: context.stderrSink,
    );
  });
  tearDown(() async {
    await context.close();
    await temporary.delete(recursive: true);
  });

  test(
    testOn: '!windows',

    'classifies remapped Xcode entries and preserves nested link payloads',
    () async {
      final app = paths.join(files.logicalRoot, 'Xcode.app');
      const relative = 'Developer/Platforms/iPhoneOS.platform/Developer/SDKs';
      final root = paths.joinAll([app, 'Contents', ...relative.split('/')]);
      await files.directory(paths.join(root, 'real')).create(recursive: true);
      await files
          .file(paths.join(root, 'real', 'header.h'))
          .writeAsString('header');
      await files.link(paths.join(root, 'alias')).create('real');
      final archive = SdkArchiveExtraction(
        runner,
        DarwinSdkRepository(runner.host, log: context.log),
        PreservedSdkArchiveLinks(runner.host),
      );

      final entries = await archive.xcodeAppEntries(app).toList();

      final header = entries.singleWhere(
        (entry) => entry.name == '$relative/real/header.h',
      );
      final alias = entries.singleWhere(
        (entry) => entry.name == '$relative/alias',
      );
      expect(String.fromCharCodes(header.data), 'header');
      expect(header.mode & sdkFileTypeMask, sdkRegularFileType);
      expect(alias.mode & sdkFileTypeMask, sdkSymbolicLinkFileType);
      expect(String.fromCharCodes(alias.data), 'real');
      expect(
        entries.where((entry) => entry.name.contains('alias/header')),
        isEmpty,
      );
      expect(Directory(files.logicalRoot).existsSync(), isFalse);
    },
  );

  test(
    'rejects mapped Xcode ancestor links escaping the selected app',
    () async {
      final app = paths.join(files.logicalRoot, 'Xcode.app');
      final outside = paths.join(files.logicalRoot, 'outside');
      await files
          .directory(paths.join(outside, 'SDKs'))
          .create(recursive: true);
      await files
          .file(paths.join(outside, 'SDKs', 'secret'))
          .writeAsString('untouched');
      final platform = paths.join(
        app,
        'Contents',
        'Developer',
        'Platforms',
        'iPhoneOS.platform',
      );
      await files.directory(platform).create(recursive: true);
      await files
          .link(paths.join(platform, 'Developer'))
          .create(files.map(outside));
      final archive = SdkArchiveExtraction(
        runner,
        DarwinSdkRepository(runner.host, log: context.log),
        PreservedSdkArchiveLinks(runner.host),
      );

      await expectLater(
        archive.xcodeAppEntries(app).toList(),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains('source escapes the app'),
          ),
        ),
      );
      expect(
        await files.file(paths.join(outside, 'SDKs', 'secret')).readAsString(),
        'untouched',
      );
    },
  );

  test(
    testOn: '!windows',

    'unlinks mapped builtin header destination without deleting its target',
    () async {
      final toolchain = paths.join(files.logicalRoot, 'toolchain');
      final bin = paths.join(toolchain, 'bin');
      await files.directory(bin).create(recursive: true);
      final swift = paths.join(bin, 'swift');
      await files.file(swift).writeAsString('fixture');
      await files.file(paths.join(bin, 'clang')).writeAsString('fixture');
      final resource = paths.join(toolchain, 'resource');
      await files
          .directory(paths.join(resource, 'include'))
          .create(recursive: true);
      await files
          .file(paths.join(resource, 'include', 'header.h'))
          .writeAsString('replacement');
      final bundle = paths.join(files.logicalRoot, 'bundle');
      final destination = paths.join(
        bundle,
        'Developer',
        'Toolchains',
        'XcodeDefault.xctoolchain',
        'usr',
        'lib',
        'swift',
        'clang',
        'include',
      );
      await files.directory(paths.dirname(destination)).create(recursive: true);
      final outside = paths.join(files.logicalRoot, 'outside');
      await files.directory(outside).create();
      await files
          .file(paths.join(outside, 'secret'))
          .writeAsString('untouched');
      await files.link(destination).create(files.map(outside));

      await SdkSwiftToolchain(
        runner,
        context.installer().toolchain.policy,
      ).replaceClangBuiltinHeaders(
        bundle,
        locateTool: (_) async => swift,
        runProcess: (_, arguments) async => arguments.contains('--version')
            ? const CapturedProcess(0, 'Swift version fixture', '')
            : CapturedProcess(0, resource, ''),
      );

      expect(files.link(destination).existsSync(), isFalse);
      expect(
        await files.file(paths.join(destination, 'header.h')).readAsString(),
        'replacement',
      );
      expect(
        await files.file(paths.join(outside, 'secret')).readAsString(),
        'untouched',
      );
      expect(Directory(files.logicalRoot).existsSync(), isFalse);
    },
  );
}

@internal
final class MappedSdkInspectionFileSystem implements HostFileSystemInterface {
  const MappedSdkInspectionFileSystem({
    required this.logicalRoot,
    required this.backingRoot,
    required this.paths,
  });
  final String logicalRoot;
  final String backingRoot;
  final p.Context paths;

  String map(String path) =>
      path == logicalRoot || paths.isWithin(logicalRoot, path)
      ? paths.join(backingRoot, paths.relative(path, from: logicalRoot))
      : path;
  String logical(String path) =>
      path == backingRoot || paths.isWithin(backingRoot, path)
      ? paths.join(logicalRoot, paths.relative(path, from: backingRoot))
      : path;

  @override
  File file(String path) =>
      MappedSdkInspectionFile(map(path), File(map(path)), this);
  @override
  Directory directory(String path) =>
      MappedSdkInspectionDirectory(logical(path), Directory(map(path)), this);
  @override
  Link link(String path) => Link(map(path));
  @override
  void makeExecutable(String path) =>
      throw UnsupportedError('fixture does not execute tools');
  @override
  void setPermissions(String path, int mode) =>
      throw UnsupportedError('fixture does not change permissions');
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      throw UnsupportedError('fixture does not install archives');
}

@internal
final class MappedSdkInspectionDirectory implements Directory {
  const MappedSdkInspectionDirectory(this.path, this.backing, this.files);
  @override
  final String path;
  final Directory backing;
  final MappedSdkInspectionFileSystem files;
  @override
  bool existsSync() => backing.existsSync();
  @override
  Future<Directory> create({bool recursive = false}) =>
      backing.create(recursive: recursive);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      backing.delete(recursive: recursive);
  @override
  Future<String> resolveSymbolicLinks() async =>
      files.logical(await backing.resolveSymbolicLinks());
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => backing
      .list(recursive: recursive, followLinks: followLinks)
      .map(
        (entity) => switch (entity) {
          Directory() => files.directory(entity.path),
          File() => MappedSdkInspectionFile(
            files.logical(entity.path),
            File(entity.path),
            files,
          ),
          _ => Link(files.logical(entity.path)),
        },
      );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(invocation.memberName.toString());
}

@internal
final class MappedSdkInspectionFile implements File {
  const MappedSdkInspectionFile(this.path, this.backing, this.files);
  @override
  final String path;
  final File backing;
  final MappedSdkInspectionFileSystem files;
  @override
  bool existsSync() => backing.existsSync();
  @override
  FileStat statSync() => backing.statSync();
  @override
  Future<String> resolveSymbolicLinks() async =>
      files.logical(await backing.resolveSymbolicLinks());
  @override
  Future<Uint8List> readAsBytes() => backing.readAsBytes();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      backing.readAsString(encoding: encoding);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => backing.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  Future<File> copy(String newPath) => backing.copy(newPath);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(invocation.memberName.toString());
}
