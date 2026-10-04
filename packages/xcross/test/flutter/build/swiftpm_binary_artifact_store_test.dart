import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/artifact_publication_lock.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';

import 'swiftpm_test_context.dart';

final _swiftPmRuntime = testSwiftPmRuntime();

final _abcChecksum = sha256.convert(utf8.encode('abc')).toString();
final _defChecksum = sha256.convert(utf8.encode('def')).toString();

void main() {
  late Directory temp;
  late SwiftPmBinaryArtifactStore store;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('xcross_swiftpm_store-');
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
    for (final content in ['abc', 'def']) {
      final archive = File(p.join(temp.path, '$content.zip'))
        ..writeAsStringSync(content);
      await store.publishArchive(
        archive,
        sha256.convert(utf8.encode(content)).toString(),
      );
    }
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('rejects extracted target admission without verified archive', () async {
    final staging = fixture(temp, 'unverified', 'A.artifactbundle', 'partial');
    await expectLater(
      store.publishTarget(
        checksum: '0' * 64,
        targetName: 'A',
        stagingRoot: staging,
        artifactDirectoryName: 'A.artifactbundle',
        metadata: const {},
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await store.findCompleteTarget('0' * 64, 'A'), isNull);
    expect(
      File(p.join(store.targetRoot('0' * 64, 'A'), '.complete')).existsSync(),
      isFalse,
    );
  });

  test(
    'does not reuse legacy completion metadata without archive provenance',
    () async {
      final entry = await publishFixture(
        store,
        temp,
        checksum: _abcChecksum,
        target: 'A',
      );
      final metadata = File(
        p.join(store.targetRoot(_abcChecksum, 'A'), 'metadata.json'),
      );
      final value =
          jsonDecode(metadata.readAsStringSync()) as Map<String, dynamic>;
      value.remove('verifiedArchiveChecksum');
      metadata.writeAsStringSync(jsonEncode(value));
      expect(Directory(entry.artifactPath).existsSync(), isTrue);
      expect(await store.findCompleteTarget(_abcChecksum, 'A'), isNull);
    },
  );

  test('publishes and reuses a verified archive', () async {
    final bytes = utf8.encode('archive');
    final checksum = sha256.convert(bytes).toString();
    final first = File(p.join(temp.path, 'first.zip'))..writeAsBytesSync(bytes);

    final published = await store.publishArchive(first, checksum);
    final second = File(p.join(temp.path, 'second.zip'))
      ..writeAsBytesSync(bytes);
    final reused = await store.publishArchive(second, checksum);

    expect(published.path, store.archivePath(checksum));
    expect(await published.readAsBytes(), bytes);
    expect(reused.path, published.path);
  });

  test('canonicalizes archive and target checksum identity', () async {
    final bytes = utf8.encode('archive');
    final checksum = sha256.convert(bytes).toString();
    final archive = File(p.join(temp.path, 'archive.zip'))
      ..writeAsBytesSync(bytes);

    final published = await store.publishArchive(
      archive,
      checksum.toUpperCase(),
    );
    final target = await publishFixture(
      store,
      temp,
      checksum: _abcChecksum.toUpperCase(),
      target: 'A',
    );

    expect(published.path, store.archivePath(checksum));
    expect(
      store.archivePath(checksum.toUpperCase()),
      store.archivePath(checksum),
    );
    expect(
      store.targetRoot(_abcChecksum.toUpperCase(), 'A'),
      store.targetRoot(_abcChecksum, 'A'),
    );
    expect(target.archiveChecksum, _abcChecksum);
    expect(await store.findCompleteTarget(_abcChecksum, 'A'), isNotNull);
  });

  test('rejects an archive with a mismatched checksum', () async {
    final archive = File(p.join(temp.path, 'bad.zip'))
      ..writeAsStringSync('archive');

    await expectLater(
      store.publishArchive(archive, '0' * 64),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  test('same archive supports distinct target entries', () async {
    final a = await publishFixture(
      store,
      temp,
      checksum: _abcChecksum,
      target: 'A',
    );
    final b = await publishFixture(
      store,
      temp,
      checksum: _abcChecksum,
      target: 'B',
    );

    expect(a.artifactPath, isNot(b.artifactPath));
    expect(store.archivePath(_abcChecksum), endsWith('$_abcChecksum.zip'));
    expect(await store.findCompleteTarget(_abcChecksum, 'A'), isNotNull);
    expect(await store.findCompleteTarget(_abcChecksum, 'B'), isNotNull);
  });

  test('separates target entries by checksum', () async {
    final a = await publishFixture(
      store,
      temp,
      checksum: _abcChecksum,
      target: 'A',
    );
    final b = await publishFixture(
      store,
      temp,
      checksum: _defChecksum,
      target: 'A',
    );

    expect(a.artifactPath, isNot(b.artifactPath));
  });

  test('does not reuse an entry without completion marker', () async {
    Directory(store.targetRoot(_abcChecksum, 'A')).createSync(recursive: true);

    expect(await store.findCompleteTarget(_abcChecksum, 'A'), isNull);
  });

  test('concurrent publication exposes one complete target', () async {
    final results = await Future.wait([
      publishFixture(
        store,
        temp,
        checksum: _abcChecksum,
        target: 'A',
        value: 'one',
      ),
      publishFixture(
        store,
        temp,
        checksum: _abcChecksum,
        target: 'A',
        value: 'two',
      ),
    ]);

    expect(results[0].artifactPath, results[1].artifactPath);
    final found = await store.findCompleteTarget(_abcChecksum, 'A');
    expect(found, isNotNull);
    expect(
      File(p.join(found!.artifactPath, 'payload')).readAsStringSync(),
      anyOf('one', 'two'),
    );
    final metadata =
        jsonDecode(
              File(
                p.join(store.targetRoot(_abcChecksum, 'A'), 'metadata.json'),
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    expect(metadata['archiveChecksum'], _abcChecksum);
    expect(metadata['targetName'], 'A');
    expect(metadata['artifactDirectoryName'], 'A.artifactbundle');
  });

  test('recovers publication from an incomplete destination', () async {
    final poisoned = Directory(store.targetRoot(_abcChecksum, 'A'))
      ..createSync(recursive: true);
    File(p.join(poisoned.path, 'partial')).writeAsStringSync('keep');

    final published = await publishFixture(
      store,
      temp,
      checksum: _abcChecksum,
      target: 'A',
    );

    expect(Directory(published.artifactPath).existsSync(), isTrue);
    expect(await store.findCompleteTarget(_abcChecksum, 'A'), isNotNull);
    final preserved = poisoned.parent
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .any(
          (entry) =>
              p.basename(entry.path) == 'partial' &&
              entry.readAsStringSync() == 'keep',
        );
    expect(preserved, isTrue);
  });

  test(
    'streams multi-chunk target files with stable mutation-sensitive digest',
    () async {
      Future<SwiftPmBinaryArtifactEntry> publishLarge(String checksum) {
        final staging = temp.createTempSync('large-$checksum-');
        final artifact = Directory(p.join(staging.path, 'A.artifactbundle'))
          ..createSync();
        final payload = File(
          p.join(artifact.path, 'payload'),
        ).openSync(mode: FileMode.write);
        final chunk = List<int>.generate(64 * 1024, (index) => index & 0xff);
        for (var index = 0; index < 48; index++) {
          payload.writeFromSync(chunk);
        }
        payload.closeSync();
        return store.publishTarget(
          checksum: checksum,
          targetName: 'A',
          stagingRoot: staging,
          artifactDirectoryName: 'A.artifactbundle',
          metadata: const {},
        );
      }

      String treeDigest(String checksum) {
        final metadata =
            jsonDecode(
                  File(
                    p.join(store.targetRoot(checksum, 'A'), 'metadata.json'),
                  ).readAsStringSync(),
                )
                as Map<String, Object?>;
        return metadata['treeDigest']! as String;
      }

      final first = await publishLarge(_abcChecksum);
      final second = await publishLarge(_defChecksum);

      expect(treeDigest(_abcChecksum), treeDigest(_defChecksum));
      final payload = File(p.join(first.artifactPath, 'payload'));
      final handle = payload.openSync(mode: FileMode.append);
      handle.writeByteSync(1);
      handle.closeSync();
      expect(await store.findCompleteTarget(_abcChecksum, 'A'), isNull);
      expect(await store.findCompleteTarget(_defChecksum, 'A'), isNotNull);
      expect(
        File(p.join(second.artifactPath, 'payload')).lengthSync(),
        3 * 1024 * 1024,
      );
    },
  );

  test('requires a real artifact directory root', () async {
    final staging = temp.createTempSync('file-artifact-');
    File(p.join(staging.path, 'A.artifactbundle')).writeAsStringSync('value');

    await expectLater(
      store.publishTarget(
        checksum: _abcChecksum,
        targetName: 'A',
        stagingRoot: staging,
        artifactDirectoryName: 'A.artifactbundle',
        metadata: const {},
      ),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  test('rejects symlinks anywhere in a staged target tree', () async {
    final staging = fixture(temp, 'linked', 'A.artifactbundle', 'value');
    final outside = File(p.join(temp.path, 'outside'))..writeAsStringSync('x');
    Link(
      p.join(staging.path, 'A.artifactbundle', 'link'),
    ).createSync(outside.path);

    await expectLater(
      store.publishTarget(
        checksum: _abcChecksum,
        targetName: 'A',
        stagingRoot: staging,
        artifactDirectoryName: 'A.artifactbundle',
        metadata: const {},
      ),
      throwsA(isA<FlutterBuildError>()),
    );
    expect(await store.findCompleteTarget(_abcChecksum, 'A'), isNull);
  });

  test('does not reuse a published tree containing a symlink', () async {
    final published = await publishFixture(
      store,
      temp,
      checksum: _abcChecksum,
      target: 'A',
    );
    final outside = File(p.join(temp.path, 'outside'))..writeAsStringSync('x');
    Link(p.join(published.artifactPath, 'link')).createSync(outside.path);

    expect(await store.findCompleteTarget(_abcChecksum, 'A'), isNull);
  });

  test('does not accept a symlink as the target root', () async {
    final elsewhere = temp.createTempSync('elsewhere-');
    File(p.join(elsewhere.path, '.complete')).writeAsStringSync('');
    final target = store.targetRoot(_abcChecksum, 'A');
    Directory(target).parent.createSync(recursive: true);
    Link(target).createSync(elsewhere.path);

    expect(await store.findCompleteTarget(_abcChecksum, 'A'), isNull);
  });

  test('rejects a Windows directory junction in a staged tree', () async {
    if (!Platform.isWindows) return;
    final staging = fixture(temp, 'junction', 'A.artifactbundle', 'value');
    final target = temp.createTempSync('junction-target-');
    final junction = p.join(staging.path, 'A.artifactbundle', 'junction');
    final created = await Process.run('cmd.exe', [
      '/d',
      '/c',
      'mklink',
      '/J',
      junction,
      target.path,
    ]);
    if (created.exitCode != 0) {
      markTestSkipped('directory junction creation is unavailable');
      return;
    }

    await expectLater(
      store.publishTarget(
        checksum: _abcChecksum,
        targetName: 'A',
        stagingRoot: staging,
        artifactDirectoryName: 'A.artifactbundle',
        metadata: const {},
      ),
      throwsA(
        isA<FlutterBuildError>().having(
          (error) => error.isSecurityFailure,
          'isSecurityFailure',
          isTrue,
        ),
      ),
    );
    expect(await store.findCompleteTarget(_abcChecksum, 'A'), isNull);
  });

  test('rejects unsafe target and artifact names', () async {
    for (final target in ['.', '..', 'A/B', r'A\B']) {
      expect(() => store.targetRoot(_abcChecksum, target), throwsArgumentError);
    }
    final staging = fixture(temp, 'unsafe', 'artifact', 'value');
    await expectLater(
      store.publishTarget(
        checksum: _abcChecksum,
        targetName: 'A',
        stagingRoot: staging,
        artifactDirectoryName: '../artifact',
        metadata: const {},
      ),
      throwsArgumentError,
    );
  });
}

Future<SwiftPmBinaryArtifactEntry> publishFixture(
  SwiftPmBinaryArtifactStore store,
  Directory temp, {
  required String checksum,
  required String target,
  String value = 'artifact',
}) {
  return store.publishTarget(
    checksum: checksum,
    targetName: target,
    stagingRoot: fixture(
      temp,
      '$checksum-$target',
      '$target.artifactbundle',
      value,
    ),
    artifactDirectoryName: '$target.artifactbundle',
    metadata: {'fixture': value},
  );
}

Directory fixture(
  Directory temp,
  String name,
  String artifactName,
  String value,
) {
  final root = temp.createTempSync('$name-');
  final artifact = Directory(p.join(root.path, artifactName))
    ..createSync(recursive: true);
  File(p.join(artifact.path, 'payload')).writeAsStringSync(value);
  return root;
}
