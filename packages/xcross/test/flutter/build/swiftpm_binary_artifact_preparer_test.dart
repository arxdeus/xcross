import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_binary_fixture.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_gate_evidence.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_artifact_preparer.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/artifact_publication_lock.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_copy_policy.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_offline_publisher.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';

import 'swiftpm_test_context.dart';

final _swiftPmRuntime = testSwiftPmRuntime();
final _windowsRuntime = testWindowsSwiftPmRuntime();
final _simulatorRuntime = testSimulatorSwiftPmRuntime();

void main() {
  late Directory temp;
  late SwiftPmBinaryArtifactStore store;
  test('selects simulator binary metadata and excludes device slice', () async {
    final fixture = createFixture(temp, 'Simulator', defaultLibraries);
    final entry = await SwiftPmBinaryArtifactPreparer(
      transport: const HttpSwiftPmArchiveTransport(
        createClient: HttpClient.new,
      ),
      copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
      store: store,

      policy: _simulatorRuntime.targetPolicy,
    ).prepareDownloadedArchive(target: fixture.target, archive: fixture.file);
    expect(
      Directory(
        p.join(entry.artifactPath, 'ios-arm64_x86_64-simulator'),
      ).existsSync(),
      isTrue,
    );
    expect(
      Directory(p.join(entry.artifactPath, 'ios-arm64_armv7')).existsSync(),
      isFalse,
    );
    final libraries =
        readPlist(
              p.join(entry.artifactPath, 'Info.plist'),
            )['AvailableLibraries']!
            as List;
    expect(libraries, hasLength(1));
    expect((libraries.single as Map)['SupportedPlatformVariant'], 'simulator');
  });

  test(
    'rejects simulator binary request when only device slice exists',
    () async {
      final fixture = createFixture(temp, 'DeviceOnly', [
        defaultLibraries.first,
      ]);
      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
          store: store,

          policy: _simulatorRuntime.targetPolicy,
        ).prepareDownloadedArchive(
          target: fixture.target,
          archive: fixture.file,
        ),
        throwsBuildErrorContaining('simulator library'),
      );
    },
  );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('xcross_swiftpm_preparer-');
    store = SwiftPmBinaryArtifactStore(
      p.join(temp.path, 'store'),
      host: _swiftPmRuntime.host,
      publicationCoordinator: SwiftPmPublicationCoordinator(
        locks: FileSwiftPmPublicationLockProvider(
          _swiftPmRuntime.artifactFileSystem,
        ),
        pathKey: _swiftPmRuntime.host.paths.pathKey,
      ),
      fileSystem: _swiftPmRuntime.artifactFileSystem,
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test(
    'offline partial tree never poisons later verified archive preparation',
    () async {
      final fixture = createFixture(temp, 'Offline', defaultLibraries);
      final staging = temp.createTempSync('offline-input-');
      final partial = Directory(p.join(staging.path, 'Offline.xcframework'))
        ..createSync();
      File(p.join(partial.path, 'Info.plist')).writeAsStringSync('malformed');
      File(p.join(staging.path, '.complete')).writeAsStringSync('');
      File(p.join(staging.path, 'metadata.json')).writeAsStringSync('{}');
      final destination = p.join(temp.path, 'offline-output');
      final publisher = SwiftPmOfflineArtifactPublisher(
        fileSystem: store.fileSystem,
        publicationCoordinator: store.publicationCoordinator,
      );
      final offline = await publisher.publish(
        stagingRoot: staging,
        destination: destination,
        artifactDirectoryName: 'Offline.xcframework',
      );
      expect(
        File(p.join(offline, 'Info.plist')).readAsStringSync(),
        'malformed',
      );
      expect(File(p.join(destination, '.complete')).existsSync(), isFalse);
      expect(File(p.join(destination, 'metadata.json')).existsSync(), isFalse);
      expect(
        await store.findCompleteTarget(fixture.target.checksum, 'Offline'),
        isNull,
      );
      final entry = await SwiftPmBinaryArtifactPreparer(
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
      ).prepareDownloadedArchive(target: fixture.target, archive: fixture.file);
      expect(entry.artifactPath, isNot(offline));
      expect(
        readPlist(
          p.join(entry.artifactPath, 'Info.plist'),
        )['AvailableLibraries'],
        isA<List<Object?>>(),
      );
      expect(
        await store.findCompleteTarget(fixture.target.checksum, 'Offline'),
        isNotNull,
      );
      expect(
        await publisher.publish(
          stagingRoot: staging,
          destination: destination,
          artifactDirectoryName: 'Offline.xcframework',
        ),
        offline,
      );
      File(p.join(offline, 'Info.plist')).writeAsStringSync('changed');
      await expectLater(
        publisher.publish(
          stagingRoot: staging,
          destination: destination,
          artifactDirectoryName: 'Offline.xcframework',
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('distinct preparers share session destination serialization', () async {
    final fixture = createFixture(
      temp,
      'ConcurrentInstances',
      defaultLibraries,
    );
    final initial = SwiftPmBinaryArtifactPreparer(
      store: store,
      policy: _swiftPmRuntime.targetPolicy,
      transport: const HttpSwiftPmArchiveTransport(
        createClient: HttpClient.new,
      ),
      copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
    );
    final entry = await initial.prepareDownloadedArchive(
      target: fixture.target,
      archive: fixture.file,
    );
    final secondStore = SwiftPmBinaryArtifactStore(
      store.root,
      host: store.host,
      fileSystem: store.fileSystem,
      publicationCoordinator: store.publicationCoordinator,
    );
    final second = SwiftPmBinaryArtifactPreparer(
      store: secondStore,
      policy: _swiftPmRuntime.targetPolicy,
      transport: const HttpSwiftPmArchiveTransport(
        createClient: HttpClient.new,
      ),
      copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
    );
    final destination = p.join(temp.path, 'shared-publication');
    final outcomes = await Future.wait([
      initial.materializeBinaryArtifact(
        source: entry.artifactPath,
        destination: destination,
      ),
      second.materializeBinaryArtifact(
        source: entry.artifactPath,
        destination: destination,
      ),
    ]);
    expect(outcomes.where((value) => value.nonce != null), hasLength(1));
    expect(outcomes.where((value) => value.nonce == null), hasLength(1));
  });

  test('generates deterministic SwiftPM XCFramework ZIP fixture', () {
    final first = SwiftPmBinaryFixture.generate(
      root: p.join(temp.path, 'first'),
      archiveUrl: Uri.parse('http://127.0.0.1:8123/BinaryFixture.zip'),
    );
    final second = SwiftPmBinaryFixture.generate(
      root: p.join(temp.path, 'second'),
      archiveUrl: Uri.parse('http://127.0.0.1:8123/BinaryFixture.zip'),
    );

    expect(first.archive.readAsBytesSync(), second.archive.readAsBytesSync());
    expect(first.checksum, second.checksum);
    final manifest = File(
      p.join(
        first.pluginRoot.path,
        'ios',
        'binary_fixture_plugin',
        'Package.swift',
      ),
    ).readAsStringSync();
    expect(manifest, contains('checksum: "${first.checksum}"'));
    expect(manifest, contains('.binaryTarget'));
    final decoded = ZipDecoder().decodeBytes(first.archive.readAsBytesSync());
    final binary = decoded.files.singleWhere(
      (entry) => entry.name.endsWith('/BinaryFixture'),
    );
    final bytes = binary.content as List<int>;
    expect(bytes, hasLength(greaterThan(32)));
    expect(utf8.decode(bytes.take(8).toList()), '!<arch>\n');
  });

  test('selects metadata device slice and excludes simulator slice', () async {
    final fixture = createFixture(temp, 'Fixture', defaultLibraries);

    final entry = await SwiftPmBinaryArtifactPreparer(
      transport: const HttpSwiftPmArchiveTransport(
        createClient: HttpClient.new,
      ),
      copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
      store: store,
      policy: _swiftPmRuntime.targetPolicy,
    ).prepareDownloadedArchive(target: fixture.target, archive: fixture.file);

    expect(
      File(
        p.join(
          entry.artifactPath,
          'ios-arm64_armv7',
          'Fixture.framework',
          'Fixture',
        ),
      ).readAsStringSync(),
      'device',
    );
    expect(
      Directory(
        p.join(entry.artifactPath, 'ios-arm64_x86_64-simulator'),
      ).existsSync(),
      isFalse,
    );
    final plist = readPlist(p.join(entry.artifactPath, 'Info.plist'));
    final availableLibraries = plist['AvailableLibraries']! as List;
    expect(availableLibraries, hasLength(1));
    expect(
      (availableLibraries.single! as Map)['LibraryIdentifier'],
      'ios-arm64_armv7',
    );
  });

  test('requires exactly one eligible device slice', () async {
    final noDevice = createFixture(temp, 'None', [defaultLibraries.last]);
    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(
        target: noDevice.target,
        archive: noDevice.file,
      ),
      throwsBuildErrorContaining('exactly one'),
    );

    final duplicate = createFixture(temp, 'Duplicate', [
      defaultLibraries.first,
      {...defaultLibraries.first, 'LibraryIdentifier': 'ios-arm64-other'},
    ]);
    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(
        target: duplicate.target,
        archive: duplicate.file,
      ),
      throwsBuildErrorContaining('exactly one'),
    );
  });

  test('requires declared library path to be retained', () async {
    final fixture = createFixture(
      temp,
      'Missing',
      defaultLibraries,
      omitDeviceLibrary: true,
    );

    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(target: fixture.target, archive: fixture.file),
      throwsBuildErrorContaining('LibraryPath'),
    );
  });

  test('prepares two targets from one archive independently', () async {
    final archive = Archive();
    addEntries(archive, xcframeworkEntries('A', defaultLibraries));
    addEntries(archive, xcframeworkEntries('B', defaultLibraries));
    final file = writeArchive(temp, 'both.zip', archive);
    final checksum = sha256.convert(file.readAsBytesSync()).toString();
    final preparer = SwiftPmBinaryArtifactPreparer(
      transport: const HttpSwiftPmArchiveTransport(
        createClient: HttpClient.new,
      ),
      copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
      store: store,
      policy: _swiftPmRuntime.targetPolicy,
    );

    final a = await preparer.prepareDownloadedArchive(
      target: target('A', checksum),
      archive: file,
    );
    final b = await preparer.prepareDownloadedArchive(
      target: target('B', checksum),
      archive: file,
    );

    expect(a.artifactPath, isNot(b.artifactPath));
    expect(p.basename(a.artifactPath), 'A.xcframework');
    expect(p.basename(b.artifactPath), 'B.xcframework');
  });

  test('downloads, verifies, publishes, and reuses prepared target', () async {
    final source = createFixture(temp, 'Download', defaultLibraries);
    var downloads = 0;
    final preparer = SwiftPmBinaryArtifactPreparer(
      transport: CallbackSwiftPmArchiveTransport((
        url,
        destination,
        maximumBytes,
      ) async {
        downloads++;
        await source.file.copy(destination.path);
      }),
      copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
      store: store,

      policy: _swiftPmRuntime.targetPolicy,
    );

    final first = await preparer.prepare(source.target);
    final second = await preparer.prepare(source.target);

    expect(first.entry.artifactPath, second.entry.artifactPath);
    expect(first.target, same(source.target));
    expect(downloads, 1);
    expect(
      File(store.archivePath(source.target.checksum)).existsSync(),
      isTrue,
    );
  });

  test('does not soften checksum mismatch', () async {
    final source = createFixture(temp, 'BadChecksum', defaultLibraries);
    final badTarget = target('BadChecksum', '0' * 64);
    final preparer = SwiftPmBinaryArtifactPreparer(
      transport: CallbackSwiftPmArchiveTransport(
        (url, destination, maximumBytes) => source.file.copy(destination.path),
      ),
      copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
      store: store,

      policy: _swiftPmRuntime.targetPolicy,
    );

    await expectLater(
      preparer.prepare(badTarget),
      throwsBuildErrorContaining('checksum mismatch'),
    );
  });

  for (final unsafe in [
    '../escape',
    '/absolute',
    'C:/drive',
    'bad\u0000name',
  ]) {
    test(
      'rejects unsafe ZIP path ${unsafe.replaceAll('\u0000', '<NUL>')}',
      () async {
        final fixture = createFixture(
          temp,
          'Unsafe${unsafe.hashCode}',
          defaultLibraries,
          extraEntries: [ArchiveFile.string(unsafe, 'bad')],
        );

        await expectLater(
          SwiftPmBinaryArtifactPreparer(
            transport: const HttpSwiftPmArchiveTransport(
              createClient: HttpClient.new,
            ),
            copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
            store: store,
            policy: _swiftPmRuntime.targetPolicy,
          ).prepareDownloadedArchive(
            target: fixture.target,
            archive: fixture.file,
          ),
          throwsBuildErrorContaining('unsafe'),
        );
        expect(File(p.join(temp.path, 'escape')).existsSync(), isFalse);
      },
    );
  }

  test('rejects case-folded destination collision', () async {
    final fixture = createFixture(
      temp,
      'CaseCollision',
      defaultLibraries,
      extraEntries: [
        ArchiveFile.string('Foo', 'one'),
        ArchiveFile.string('foo', 'one'),
      ],
    );

    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(target: fixture.target, archive: fixture.file),
      throwsBuildErrorContaining('collision'),
    );
  });

  test('rejects duplicate path with conflicting bytes', () async {
    final fixture = createFixture(
      temp,
      'DuplicatePath',
      defaultLibraries,
      extraEntries: [
        ArchiveFile.string('duplicateA', 'one'),
        ArchiveFile.string('duplicateB', 'two'),
      ],
    );
    replaceAscii(fixture.file, 'duplicateB', 'duplicateA');
    final duplicateTarget = target(
      'DuplicatePath',
      sha256.convert(fixture.file.readAsBytesSync()).toString(),
    );

    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(
        target: duplicateTarget,
        archive: fixture.file,
      ),
      throwsBuildErrorContaining('duplicate'),
    );
  });

  test('enforces compressed archive byte limit before decode', () async {
    final fixture = createFixture(temp, 'CompressedBytes', defaultLibraries);

    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        maxArchiveBytes: fixture.file.lengthSync() - 1,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(target: fixture.target, archive: fixture.file),
      throwsBuildErrorContaining('archive byte limit'),
    );
  });

  test(
    'rejects announced oversized download before persisting bytes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        request.response.contentLength = 11;
        request.response.add(List<int>.filled(11, 1));
        await request.response.close();
      });
      final remote = SwiftPmRemoteBinaryTarget(
        name: 'AnnouncedOversize',
        url: Uri.parse(
          'http://${server.address.host}:${server.port}/archive.zip',
        ),
        checksum: '0' * 64,
        start: 0,
        end: 0,
      );

      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
          store: store,
          maxArchiveBytes: 10,
          policy: _swiftPmRuntime.targetPolicy,
        ).prepare(remote),
        throwsBuildErrorContaining(
          'SwiftPM binary artifact exceeds compressed archive byte limit',
        ),
      );

      expect(File(store.archivePath(remote.checksum)).existsSync(), isFalse);
      expect(await stagingFiles(store), isEmpty);
    },
  );

  test(
    'aborts chunked oversized download without persisting past limit',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        request.response
          ..add(List<int>.filled(6, 1))
          ..add(List<int>.filled(6, 2));
        await request.response.close();
      });
      final remote = SwiftPmRemoteBinaryTarget(
        name: 'ChunkedOversize',
        url: Uri.parse(
          'http://${server.address.host}:${server.port}/archive.zip',
        ),
        checksum: '0' * 64,
        start: 0,
        end: 0,
      );

      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
          store: store,
          maxArchiveBytes: 10,
          policy: _swiftPmRuntime.targetPolicy,
        ).prepare(remote),
        throwsBuildErrorContaining(
          'SwiftPM binary artifact exceeds compressed archive byte limit',
        ),
      );

      expect(File(store.archivePath(remote.checksum)).existsSync(), isFalse);
      expect(await stagingFiles(store), isEmpty);
    },
  );

  for (final unsafe in [
    'CON',
    'nul.txt',
    'AUX.tar.gz',
    'COM1.txt',
    r'clock$.log',
    'bad?name',
    'trailing.',
    'trailing ',
    'stream:ads',
    'control\u0001name',
    'caf\u00e9',
  ]) {
    test('rejects Windows-unsafe ZIP component $unsafe', () async {
      final fixture = createFixture(
        temp,
        'WindowsUnsafe${unsafe.hashCode.abs()}',
        defaultLibraries,
        extraEntries: [ArchiveFile.string('directory/$unsafe', 'bad')],
      );

      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
          store: store,
          policy: _swiftPmRuntime.targetPolicy,
        ).prepareDownloadedArchive(
          target: fixture.target,
          archive: fixture.file,
        ),
        throwsBuildErrorContaining('unsafe'),
      );
    });
  }

  test('rejects Windows-unsafe plist paths', () async {
    final fixture = createFixture(temp, 'UnsafeMetadata', [
      {...defaultLibraries.first, 'LibraryPath': 'NUL.framework'},
    ]);

    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(target: fixture.target, archive: fixture.file),
      throwsBuildErrorContaining('LibraryPath is unsafe'),
    );
  });

  test('wraps archive decode failures', () async {
    final file = File(p.join(temp.path, 'invalid.zip'))
      ..writeAsStringSync('not a ZIP');
    final invalidTarget = target(
      'Invalid',
      sha256.convert(file.readAsBytesSync()).toString(),
    );

    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(target: invalidTarget, archive: file),
      throwsBuildErrorContaining('not a valid ZIP'),
    );
  });

  test(
    'does not decompress unselected slice files during inspection',
    () async {
      final fixture = createFixture(
        temp,
        'IgnoredCorruption',
        defaultLibraries,
      );
      corruptZipEntry(
        fixture.file,
        'IgnoredCorruption.xcframework/'
        'ios-arm64_x86_64-simulator/Fixture.framework/Fixture',
      );
      final updatedTarget = target(
        'IgnoredCorruption',
        sha256.convert(fixture.file.readAsBytesSync()).toString(),
      );

      final entry = await SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(target: updatedTarget, archive: fixture.file);

      expect(
        File(
          p.join(
            entry.artifactPath,
            'ios-arm64_armv7',
            'Fixture.framework',
            'Fixture',
          ),
        ).readAsStringSync(),
        'device',
      );
    },
  );

  test('wraps selected slice decompression failures', () async {
    final fixture = createFixture(temp, 'CorruptSelected', defaultLibraries);
    corruptZipEntry(
      fixture.file,
      'CorruptSelected.xcframework/'
      'ios-arm64_armv7/Fixture.framework/Fixture',
    );
    final updatedTarget = target(
      'CorruptSelected',
      sha256.convert(fixture.file.readAsBytesSync()).toString(),
    );

    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(target: updatedTarget, archive: fixture.file),
      throwsBuildErrorContaining('could not be decompressed'),
    );
  });

  test('enforces archive entry limit', () async {
    final fixture = createFixture(temp, 'Entries', defaultLibraries);

    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        maxEntries: 2,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(target: fixture.target, archive: fixture.file),
      throwsBuildErrorContaining('entry limit'),
    );
  });

  test('enforces expanded byte limit', () async {
    final fixture = createFixture(temp, 'Bytes', defaultLibraries);

    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        maxExpandedBytes: 10,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(target: fixture.target, archive: fixture.file),
      throwsBuildErrorContaining('expanded byte limit'),
    );
  });

  test('declines selected slices that depend on symlinks', () async {
    final link = ArchiveFile.string(
      'Linked.xcframework/ios-arm64_armv7/Fixture.framework/Fixture',
      'Versions/Current/Fixture',
    )..mode = 0xa1ff;
    final fixture = createFixture(
      temp,
      'Linked',
      defaultLibraries,
      omitDeviceLibrary: true,
      extraEntries: [link],
    );
    markZipEntryAsUnix(fixture.file, link.name);
    final linkedTarget = target(
      'Linked',
      sha256.convert(fixture.file.readAsBytesSync()).toString(),
    );

    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(target: linkedTarget, archive: fixture.file),
      throwsBuildErrorContaining('unsupported'),
    );
    expect(
      await store.findCompleteTarget(linkedTarget.checksum, 'Linked'),
      isNull,
    );
  });

  test('rejects malformed plist shapes without cast errors', () async {
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'Malformed.xcframework/Info.plist',
          PropertyListSerialization.stringWithPropertyList({
            'AvailableLibraries': ['not a dictionary'],
          }),
        ),
      );
    final file = writeArchive(temp, 'malformed.zip', archive);
    final checksum = sha256.convert(file.readAsBytesSync()).toString();

    await expectLater(
      SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(
        target: target('Malformed', checksum),
        archive: file,
      ),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  group('artifact aliases', () {
    test('recognizes only the Windows mount-point reparse tag', () {
      expect(
        isWindowsMountPointReparseOutput(
          'Reparse Tag Value : 0xa0000003\nTag value: Microsoft Mount Point',
        ),
        isTrue,
      );
      expect(
        isWindowsMountPointReparseOutput(
          'Reparse Tag Value : 0xA000000C\nTag value: Microsoft Symbolic Link',
        ),
        isFalse,
      );
      expect(
        isWindowsMountPointReparseOutput('Reparse point found with no tag'),
        isFalse,
      );
    });

    test('requires a complete store entry', () async {
      final alias = p.join(temp.path, 'alias');
      final incomplete = p.join(temp.path, 'incomplete');
      Directory(incomplete).createSync();

      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
          store: store,
          policy: _swiftPmRuntime.targetPolicy,
        ).createBinaryArtifactJunction(alias: alias, target: incomplete),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        FileSystemEntity.typeSync(alias, followLinks: false),
        FileSystemEntityType.notFound,
      );
    });

    test('refuses to replace or remove an ordinary directory', () async {
      final fixture = createFixture(temp, 'Unowned', defaultLibraries);
      final entry = await SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).prepareDownloadedArchive(target: fixture.target, archive: fixture.file);
      final alias = Directory(p.join(temp.path, 'ordinary'))..createSync();
      final sentinel = File(p.join(alias.path, 'keep'))
        ..writeAsStringSync('safe');
      final preparer = SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      );

      await expectLater(
        preparer.createBinaryArtifactJunction(
          alias: alias.path,
          target: entry.artifactPath,
        ),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        preparer.removeBinaryArtifactAlias(alias.path),
        throwsA(isA<FileSystemException>()),
      );

      expect(sentinel.readAsStringSync(), 'safe');
    });

    test('stale marker does not authorize removing a real directory', () async {
      final alias = Directory(p.join(temp.path, 'stale-real'))..createSync();
      final sentinel = File(p.join(alias.path, 'keep'))
        ..writeAsStringSync('safe');
      writeAliasMarker(alias.path, p.join(temp.path, 'missing-target'));

      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
          store: store,
          policy: _swiftPmRuntime.targetPolicy,
        ).removeBinaryArtifactAlias(alias.path),
        throwsA(isA<FileSystemException>()),
      );

      expect(sentinel.readAsStringSync(), 'safe');
    });

    test('mismatched marker does not authorize a retargeted alias', () async {
      final first = Directory(p.join(temp.path, 'first'))..createSync();
      final second = Directory(p.join(temp.path, 'second'))..createSync();
      final alias = p.join(temp.path, 'retargeted');
      await Link(alias).create(second.path);
      writeAliasMarker(alias, first.path);

      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
          store: store,
          policy: _swiftPmRuntime.targetPolicy,
        ).removeBinaryArtifactAlias(alias),
        throwsA(isA<FileSystemException>()),
      );

      expect(Link(alias).existsSync(), isTrue);
      expect(second.existsSync(), isTrue);
    }, skip: Platform.isWindows ? 'uses a Unix symlink fixture' : false);

    test('marker for the wrong alias type cannot authorize removal', () async {
      final alias = File(p.join(temp.path, 'wrong-type'))
        ..writeAsStringSync('safe');
      writeAliasMarker(alias.path, temp.path);

      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
          store: store,
          policy: _swiftPmRuntime.targetPolicy,
        ).removeBinaryArtifactAlias(alias.path),
        throwsA(isA<FileSystemException>()),
      );

      expect(alias.readAsStringSync(), 'safe');
    });

    test('interrupted marker publication cannot own a later path', () async {
      final alias = p.join(temp.path, 'interrupted');
      writeAliasMarker(alias, temp.path, suffix: '.tmp-interrupted');
      final real = Directory(alias)..createSync();
      final sentinel = File(p.join(real.path, 'keep'))
        ..writeAsStringSync('safe');

      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
          store: store,
          policy: _swiftPmRuntime.targetPolicy,
        ).removeBinaryArtifactAlias(alias),
        throwsA(isA<FileSystemException>()),
      );

      expect(sentinel.readAsStringSync(), 'safe');
    });

    test(
      'replacing and removing a managed alias preserves its target',
      () async {
        final fixture = createFixture(temp, 'Alias', defaultLibraries);
        final entry =
            await SwiftPmBinaryArtifactPreparer(
              transport: const HttpSwiftPmArchiveTransport(
                createClient: HttpClient.new,
              ),
              copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
              store: store,
              policy: _swiftPmRuntime.targetPolicy,
            ).prepareDownloadedArchive(
              target: fixture.target,
              archive: fixture.file,
            );
        final alias = p.join(temp.path, 'alias');
        final preparer = SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
          store: store,
          policy: _swiftPmRuntime.targetPolicy,
        );
        await preparer.createBinaryArtifactJunction(
          alias: alias,
          target: entry.artifactPath,
        );
        await preparer.createBinaryArtifactJunction(
          alias: alias,
          target: entry.artifactPath,
        );
        await preparer.removeBinaryArtifactAlias(alias);

        expect(Directory(alias).existsSync(), isFalse);
        expect(
          File(p.join(entry.artifactPath, 'Info.plist')).existsSync(),
          isTrue,
        );
      },
    );
  });

  group('Windows alias feasibility gates', () {
    Future<void> expectProductionProbe(SwiftPmGateMode mode) async {
      final sdk = _windowsRuntime.sdkRepository.current()!;
      expect(
        await _windowsRuntime.hostPolicy.gatePlatform.probe(
          _windowsRuntime,
          mode: mode,
          root: temp.path,
          toolchainIdentity: jsonEncode(
            await _swiftPmRuntime.toolchain.resolveBuildToolchainIdentity(sdk),
          ),
          sdkIdentity: jsonEncode(
            await _windowsRuntime.sdkIdentity.sdkBuildIdentity(
              sdk.swiftSdkPath,
            ),
          ),
        ),
        isTrue,
      );
    }

    test(
      'package-local junction survives repeated resolve and cross-build',
      () => expectProductionProbe(SwiftPmGateMode.packageLocalArtifact),
      skip: windowsGateSkip,
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test(
      'SwiftPM artifact junction survives repeated resolve and cross-build',
      () => expectProductionProbe(SwiftPmGateMode.swiftPmArtifact),
      skip: windowsGateSkip,
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });

  group('bounded materialization', () {
    Future<String> source(String name) async {
      final fixture = createFixture(temp, name, defaultLibraries);
      return (await SwiftPmBinaryArtifactPreparer(
            transport: const HttpSwiftPmArchiveTransport(
              createClient: HttpClient.new,
            ),
            copyPolicy: PosixSwiftPmArtifactCopyPolicy(store.fileSystem),
            store: store,
            policy: _swiftPmRuntime.targetPolicy,
          ).prepareDownloadedArchive(
            target: fixture.target,
            archive: fixture.file,
          ))
          .artifactPath;
    }

    for (var exitCode = 0; exitCode <= 7; exitCode++) {
      test('accepts Robocopy exit code $exitCode', () async {
        final artifact = await source('Success$exitCode');
        final destination = p.join(temp.path, 'destination-$exitCode');
        final process = FakeProcess(exitValue: exitCode);
        final outcome = await SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: WindowsSwiftPmArtifactCopyPolicy(
            fileSystem: store.fileSystem,
            startProcess: (_, arguments) async {
              copyDirectorySync(artifact, arguments[1]);
              return process;
            },
          ),
          store: store,
          policy: _swiftPmRuntime.targetPolicy,
        ).materializeBinaryArtifact(source: artifact, destination: destination);
        expect(outcome, SwiftPmBinaryArtifactPublication.published());
        expect(process.killed, isFalse);
        expect(Directory(destination).existsSync(), isTrue);
      });
    }

    test('reports a concurrent identical publisher as reused', () async {
      final artifact = await source('ConcurrentPublisher');
      final destination = p.join(temp.path, 'concurrent-destination');

      final outcome = await SwiftPmBinaryArtifactPreparer(
        transport: const HttpSwiftPmArchiveTransport(
          createClient: HttpClient.new,
        ),
        copyPolicy: WindowsSwiftPmArtifactCopyPolicy(
          fileSystem: store.fileSystem,
          startProcess: (_, arguments) async {
            copyDirectorySync(artifact, arguments[1]);
            copyDirectorySync(artifact, destination);
            return FakeProcess(exitValue: 0);
          },
        ),
        store: store,
        policy: _swiftPmRuntime.targetPolicy,
      ).materializeBinaryArtifact(source: artifact, destination: destination);

      expect(outcome, SwiftPmBinaryArtifactPublication.reused);
      expect(Directory(destination).existsSync(), isTrue);
    });

    test('failed copy leaves no final or temporary destination', () async {
      final artifact = await source('FailedCopy');
      final destination = p.join(temp.path, 'failed-destination');
      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: WindowsSwiftPmArtifactCopyPolicy(
            fileSystem: store.fileSystem,
            startProcess: (_, arguments) async {
              File(p.join(arguments[1], 'partial'))
                ..createSync(recursive: true)
                ..writeAsStringSync('partial');
              return FakeProcess(exitValue: 8);
            },
          ),
          store: store,
          policy: _swiftPmRuntime.targetPolicy,
        ).materializeBinaryArtifact(source: artifact, destination: destination),
        throwsA(isA<FileSystemException>()),
      );
      expectMaterializationAbsent(destination);
    });

    test('rejects Robocopy exit code 8 with bounded diagnostics', () async {
      final artifact = await source('Diagnostics');
      final process = FakeProcess(
        exitValue: 8,
        stdoutText: 'o' * 5000,
        stderrText: 'e' * 5000,
      );
      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: WindowsSwiftPmArtifactCopyPolicy(
            fileSystem: store.fileSystem,
            startProcess: (_, _) async => process,
          ),
          store: store,
          policy: _swiftPmRuntime.targetPolicy,
        ).materializeBinaryArtifact(
          source: artifact,
          destination: p.join(temp.path, 'diagnostic-destination'),
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message.length,
            'bounded message length',
            lessThan(3000),
          ),
        ),
      );
    });

    test(
      'kills timed out copy and removes its temporary destination',
      () async {
        final artifact = await source('Timeout');
        final destination = p.join(temp.path, 'timeout-destination');
        final process = FakeBinaryCopyProcess();
        final future =
            SwiftPmBinaryArtifactPreparer(
              transport: const HttpSwiftPmArchiveTransport(
                createClient: HttpClient.new,
              ),
              copyPolicy: WindowsSwiftPmArtifactCopyPolicy(
                fileSystem: store.fileSystem,
                startProcess: (_, arguments) async {
                  File(p.join(arguments[1], 'partial'))
                    ..createSync(recursive: true)
                    ..writeAsStringSync('partial');
                  return process;
                },
              ),
              store: store,
              policy: _swiftPmRuntime.targetPolicy,
            ).materializeBinaryArtifact(
              source: artifact,
              destination: destination,
              timeout: const Duration(milliseconds: 1),
            );

        await expectLater(future, throwsA(isA<FileSystemException>()));
        expect(process.killed, isTrue);
        expect(process.exitObservedAfterKill, isTrue);
        expectMaterializationAbsent(destination);
      },
    );

    for (final throwOnKill in [false, true]) {
      test(
        'retains live copy when quarantine marker fails, kill throws $throwOnKill',
        () async {
          final artifact = await source('QuarantineFailure$throwOnKill');
          final destination = p.join(
            temp.path,
            'quarantine-failed-$throwOnKill',
          );
          final process = FakeBinaryCopyProcess(
            killResult: false,
            exitAfterKill: false,
            throwOnKill: throwOnKill,
          );
          String? temporary;
          final copyPolicy = WindowsSwiftPmArtifactCopyPolicy(
            fileSystem: FailingQuarantineFileSystem(store.fileSystem),
            startProcess: (_, arguments) async {
              temporary = arguments[1];
              File(p.join(temporary!, 'partial')).writeAsStringSync('live');
              return process;
            },
          );
          final preparer = SwiftPmBinaryArtifactPreparer(
            store: store,
            policy: _swiftPmRuntime.targetPolicy,
            transport: const HttpSwiftPmArchiveTransport(
              createClient: HttpClient.new,
            ),
            copyPolicy: copyPolicy,
          );
          await expectLater(
            preparer.materializeBinaryArtifact(
              source: artifact,
              destination: destination,
              timeout: const Duration(milliseconds: 1),
            ),
            throwsA(
              isA<SwiftPmLiveCopyException>().having(
                (error) => error.message,
                'message',
                contains('quarantine marker failed'),
              ),
            ),
          );
          expect(Directory(temporary!).existsSync(), isTrue);
          expect(
            File(p.join(temporary!, 'partial')).readAsStringSync(),
            'live',
          );
          expect(Directory(destination).existsSync(), isFalse);
          process.complete(8);
        },
      );
    }

    test('quarantines a live timed-out copy until it exits', () async {
      final artifact = await source('KillRefusal');
      final destination = p.join(temp.path, 'refused-destination');
      final process = FakeBinaryCopyProcess(
        killResult: false,
        exitAfterKill: false,
      );
      String? temporary;
      final stopwatch = Stopwatch()..start();

      await expectLater(
        SwiftPmBinaryArtifactPreparer(
          transport: const HttpSwiftPmArchiveTransport(
            createClient: HttpClient.new,
          ),
          copyPolicy: WindowsSwiftPmArtifactCopyPolicy(
            fileSystem: store.fileSystem,
            startProcess: (_, arguments) async {
              temporary = arguments[1];
              File(p.join(temporary!, 'partial'))
                ..createSync(recursive: true)
                ..writeAsStringSync('partial');
              return process;
            },
          ),
          store: store,
          policy: _swiftPmRuntime.targetPolicy,
        ).materializeBinaryArtifact(
          source: artifact,
          destination: destination,
          timeout: const Duration(milliseconds: 1),
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            allOf(contains('kill returned false'), contains('grace period')),
          ),
        ),
      );

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(Directory(destination).existsSync(), isFalse);
      expect(Directory(temporary!).existsSync(), isTrue);
      File(p.join(temporary!, 'still-writing')).writeAsStringSync('safe');

      expect(
        File(p.join(temporary!, '.xcross-live-copy-quarantine')).existsSync(),
        isTrue,
      );
      process.complete(8);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(Directory(temporary!).existsSync(), isTrue);
      expect(Directory(destination).existsSync(), isFalse);
    });
  });
}

Future<List<File>> stagingFiles(SwiftPmBinaryArtifactStore store) async {
  final staging = Directory(p.join(store.root, '.staging'));
  if (!staging.existsSync()) return const [];
  return [
    await for (final entity in staging.list(recursive: true))
      if (entity is File) entity,
  ];
}

void copyDirectorySync(String source, String destination) {
  for (final entity in Directory(source).listSync(recursive: true)) {
    final relative = p.relative(entity.path, from: source);
    final output = p.join(destination, relative);
    if (entity is Directory) {
      Directory(output).createSync(recursive: true);
    } else if (entity is File) {
      File(output).createSync(recursive: true);
      entity.copySync(output);
    }
  }
}

void expectMaterializationAbsent(String destination) {
  expect(
    FileSystemEntity.typeSync(destination, followLinks: false),
    FileSystemEntityType.notFound,
  );
  final parent = Directory(p.dirname(destination));
  final temporaryPrefix = '.${p.basename(destination)}.xcross-copy-';
  expect(
    parent
        .listSync(followLinks: false)
        .where((entity) => p.basename(entity.path).startsWith(temporaryPrefix)),
    isEmpty,
  );
}

void writeAliasMarker(String alias, String target, {String suffix = ''}) {
  File('$alias.xcross-alias.json$suffix').writeAsStringSync(
    jsonEncode({
      'alias': p.normalize(p.absolute(alias)),
      'target': p.normalize(p.absolute(target)),
    }),
  );
}

final windowsGateSkip = !Platform.isWindows
    ? 'Windows-only SwiftPM junction feasibility gate'
    : (Platform.environment['XCROSS_SWIFT_SDKS_PATH'] == null
          ? 'XCROSS_SWIFT_SDKS_PATH is unavailable'
          : false);

Directory createRawXcframework(Directory temp, String name) {
  final framework = Directory(p.join(temp.path, '$name.xcframework'));
  File(p.join(framework.path, 'Info.plist'))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      PropertyListSerialization.stringWithPropertyList({
        'AvailableLibraries': [
          {
            'LibraryIdentifier': 'ios-arm64',
            'LibraryPath': '$name.framework',
            'SupportedArchitectures': ['arm64'],
            'SupportedPlatform': 'ios',
          },
        ],
      }),
    );
  File(p.join(framework.path, 'ios-arm64', '$name.framework', name))
    ..createSync(recursive: true)
    ..writeAsBytesSync(emptyMachO());
  return framework;
}

Uint8List emptyMachO() {
  final bytes = Uint8List(32);
  ByteData.sublistView(bytes).setUint32(0, 0xfeedfacf, Endian.little);
  return bytes;
}

File writeRawXcframeworkZip(Directory temp, Directory fixture, String name) {
  final archive = Archive();
  for (final entity in fixture.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = p.relative(entity.path, from: fixture.parent.path);
    archive.addFile(
      ArchiveFile(relative, entity.lengthSync(), entity.readAsBytesSync()),
    );
  }
  return writeArchive(temp, name, archive);
}

const defaultLibraries = <Map<String, Object?>>[
  {
    'LibraryIdentifier': 'ios-arm64_armv7',
    'LibraryPath': 'Fixture.framework',
    'SupportedArchitectures': ['arm64', 'armv7'],
    'SupportedPlatform': 'ios',
  },
  {
    'LibraryIdentifier': 'ios-arm64_x86_64-simulator',
    'LibraryPath': 'Fixture.framework',
    'SupportedArchitectures': ['arm64', 'x86_64'],
    'SupportedPlatform': 'ios',
    'SupportedPlatformVariant': 'simulator',
  },
];

Map<String, Object?> xcframeworkPlist(List<Map<String, Object?>> libraries) => {
  'AvailableLibraries': libraries,
  'CFBundlePackageType': 'XFWK',
  'XCFrameworkFormatVersion': '1.0',
};

List<ArchiveFile> xcframeworkEntries(
  String name,
  List<Map<String, Object?>> libraries, {
  bool omitDeviceLibrary = false,
}) {
  final root = '$name.xcframework';
  final files = <ArchiveFile>[
    ArchiveFile.string(
      '$root/Info.plist',
      PropertyListSerialization.stringWithPropertyList(
        xcframeworkPlist(libraries),
      ),
    ),
  ];
  for (final library in libraries) {
    final identifier = library['LibraryIdentifier']! as String;
    if (omitDeviceLibrary && identifier == 'ios-arm64_armv7') continue;
    final value = library['SupportedPlatformVariant'] == 'simulator'
        ? 'simulator'
        : 'device';
    files.add(
      ArchiveFile.string('$root/$identifier/Fixture.framework/Fixture', value),
    );
  }
  return files;
}

ArchiveFixture createFixture(
  Directory temp,
  String name,
  List<Map<String, Object?>> libraries, {
  bool omitDeviceLibrary = false,
  List<ArchiveFile> extraEntries = const [],
}) {
  final archive = Archive();
  addEntries(
    archive,
    xcframeworkEntries(name, libraries, omitDeviceLibrary: omitDeviceLibrary),
  );
  addEntries(archive, extraEntries);
  final file = writeArchive(temp, '$name.zip', archive);
  final checksum = sha256.convert(file.readAsBytesSync()).toString();
  return ArchiveFixture(file, target(name, checksum));
}

void markZipEntryAsUnix(File file, String name) {
  final bytes = file.readAsBytesSync();
  final encodedName = utf8.encode(name);
  for (var offset = 0; offset <= bytes.length - 46; offset++) {
    if (_uint32(bytes, offset) != 0x02014b50) continue;
    final nameLength = _uint16(bytes, offset + 28);
    if (nameLength != encodedName.length) continue;
    final found = bytes.sublist(offset + 46, offset + 46 + nameLength);
    if (!_bytesEqual(found, encodedName)) continue;
    bytes[offset + 5] = 3;
  }
  file.writeAsBytesSync(bytes);
}

int _uint16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _uint32(List<int> bytes, int offset) =>
    _uint16(bytes, offset) | (_uint16(bytes, offset + 2) << 16);

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

void corruptZipEntry(File file, String name) {
  final bytes = file.readAsBytesSync();
  final encodedName = utf8.encode(name);
  for (var offset = 0; offset <= bytes.length - 46; offset++) {
    if (_uint32(bytes, offset) != 0x02014b50) continue;
    final nameLength = _uint16(bytes, offset + 28);
    if (nameLength != encodedName.length) continue;
    final found = bytes.sublist(offset + 46, offset + 46 + nameLength);
    if (!_bytesEqual(found, encodedName)) continue;
    final localOffset = _uint32(bytes, offset + 42);
    final localNameLength = _uint16(bytes, localOffset + 26);
    final localExtraLength = _uint16(bytes, localOffset + 28);
    final contentOffset = localOffset + 30 + localNameLength + localExtraLength;
    bytes[contentOffset] ^= 0xff;
    file.writeAsBytesSync(bytes);
    return;
  }
  fail('ZIP entry not found: $name');
}

void replaceAscii(File file, String from, String to) {
  final bytes = file.readAsBytesSync();
  final source = ascii.encode(from);
  final replacement = ascii.encode(to);
  expect(replacement, hasLength(source.length));
  for (var start = 0; start <= bytes.length - source.length; start++) {
    var matches = true;
    for (var offset = 0; offset < source.length; offset++) {
      if (bytes[start + offset] != source[offset]) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;
    bytes.setRange(start, start + replacement.length, replacement);
  }
  file.writeAsBytesSync(bytes);
}

void addEntries(Archive archive, Iterable<ArchiveFile> entries) {
  for (final entry in entries) {
    archive.addFile(entry);
  }
}

File writeArchive(Directory temp, String name, Archive archive) {
  final file = File(p.join(temp.path, name));
  file.writeAsBytesSync(ZipEncoder().encode(archive));
  return file;
}

SwiftPmRemoteBinaryTarget target(String name, String checksum) =>
    SwiftPmRemoteBinaryTarget(
      name: name,
      url: Uri.parse(
        'https://example.invalid/private/path/$name.zip?token=secret',
      ),
      checksum: checksum,
      start: 0,
      end: 1,
    );

Map<Object?, Object?> readPlist(String path) =>
    PropertyListSerialization.propertyListWithString(
          File(path).readAsStringSync(),
        )
        as Map<Object?, Object?>;

Matcher throwsBuildErrorContaining(String text) => throwsA(
  isA<FlutterBuildError>().having(
    (error) => error.toString().toLowerCase(),
    'message',
    contains(text.toLowerCase()),
  ),
);

final class ArchiveFixture {
  const ArchiveFixture(this.file, this.target);

  final File file;
  final SwiftPmRemoteBinaryTarget target;
}

final class FakeProcess implements BinaryCopyProcess {
  FakeProcess({this.exitValue, this.stdoutText = '', this.stderrText = ''});

  final int? exitValue;
  final String stdoutText;
  final String stderrText;
  final Completer<int> _exit = Completer<int>();
  bool killed = false;

  @override
  Future<int> get exitCode {
    if (exitValue != null && !_exit.isCompleted) _exit.complete(exitValue);
    return _exit.future;
  }

  @override
  bool kill() {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-1);
    return true;
  }

  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(stdoutText));

  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(stderrText));
}

final class FakeBinaryCopyProcess implements BinaryCopyProcess {
  FakeBinaryCopyProcess({
    this.killResult = true,
    this.exitAfterKill = true,
    this.throwOnKill = false,
  });

  final bool killResult;
  final bool exitAfterKill;
  final bool throwOnKill;
  final Completer<int> _exit = Completer<int>();
  bool killed = false;
  bool exitObservedAfterKill = false;

  @override
  Future<int> get exitCode => _exit.future.then((value) {
    exitObservedAfterKill = killed;
    return value;
  });

  @override
  bool kill() {
    killed = true;
    if (throwOnKill) throw StateError('kill failed');
    if (exitAfterKill && !_exit.isCompleted) _exit.complete(-1);
    return killResult;
  }

  void complete(int exitCode) {
    if (!_exit.isCompleted) _exit.complete(exitCode);
  }

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();
}

final class CallbackSwiftPmArchiveTransport implements SwiftPmArchiveTransport {
  const CallbackSwiftPmArchiveTransport(this.callback);
  final Future<void> Function(Uri, File, int) callback;
  @override
  Future<void> download(Uri url, File destination, int maximumBytes) =>
      callback(url, destination, maximumBytes);
}

final class FailingQuarantineFileSystem implements SwiftPmArtifactFileSystem {
  const FailingQuarantineFileSystem(this.delegate);
  final SwiftPmArtifactFileSystem delegate;
  @override
  File file(String path) => path.endsWith('.xcross-live-copy-quarantine')
      ? FailingQuarantineFile(path)
      : delegate.file(path);
  @override
  Directory directory(String path) => delegate.directory(path);
  @override
  Link link(String path) => delegate.link(path);
  @override
  FileSystemEntityType typeSync(String path, {bool followLinks = true}) =>
      delegate.typeSync(path, followLinks: followLinks);
  @override
  Future<bool> isLinkOrReparsePoint(String path) =>
      delegate.isLinkOrReparsePoint(path);
  @override
  Future<void> createAlias(String alias, String target) =>
      delegate.createAlias(alias, target);
  @override
  Future<bool> isAliasTo(String alias, String target) =>
      delegate.isAliasTo(alias, target);
  @override
  Future<void> deleteAlias(String alias) => delegate.deleteAlias(alias);
  @override
  String processPath(String path) => delegate.processPath(path);
}

final class FailingQuarantineFile implements File {
  const FailingQuarantineFile(this.path);
  @override
  final String path;
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async => throw FileSystemException('injected marker failure', path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
