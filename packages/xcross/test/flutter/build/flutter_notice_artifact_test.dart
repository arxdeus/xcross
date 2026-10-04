import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/flutter_notice_artifact.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

import '../../host_operations_fixtures.dart';

void main() {
  test(
    'copies Flutter notices into the final Flutter asset directory',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'xcross-flutter-notices-',
      );
      try {
        final sourceAssets = Directory(
          p.join(root.path, 'assemble', 'App.framework', 'flutter_assets'),
        )..createSync(recursive: true);
        final destinationAssets = Directory(
          p.join(
            root.path,
            'app.app',
            'Frameworks',
            'App.framework',
            'flutter_assets',
          ),
        )..createSync(recursive: true);
        const notice = 'example_package\n\nExample license text';
        final noticeBytes = gzip.encode(utf8.encode(notice));
        File(
          p.join(sourceAssets.path, 'NOTICES.Z'),
        ).writeAsBytesSync(noticeBytes);

        FlutterNoticeArtifact(
          fileSystem: LinuxHost(
            currentDirectory: root.path,
            temporaryDirectory: root.path,
          ).fileSystem,
          paths: p.Context(style: p.Style.posix),
        ).copy(
          sourceFlutterAssetsDirectory: sourceAssets.path,
          destinationFlutterAssetsDirectory: destinationAssets.path,
        );

        expect(
          utf8.decode(
            gzip.decode(
              File(
                p.join(destinationAssets.path, 'NOTICES.Z'),
              ).readAsBytesSync(),
            ),
          ),
          notice,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'fails when Flutter assembly does not produce license notices',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'xcross-flutter-notices-empty-',
      );
      try {
        final destinationAssets = Directory(p.join(root.path, 'destination'))
          ..createSync();

        expect(
          () =>
              FlutterNoticeArtifact(
                fileSystem: LinuxHost(
                  currentDirectory: root.path,
                  temporaryDirectory: root.path,
                ).fileSystem,
                paths: p.Context(style: p.Style.posix),
              ).copy(
                sourceFlutterAssetsDirectory: p.join(root.path, 'missing'),
                destinationFlutterAssetsDirectory: destinationAssets.path,
              ),
          throwsA(isA<FlutterBuildError>()),
        );
        expect(
          File(p.join(destinationAssets.path, 'NOTICES.Z')).existsSync(),
          isFalse,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test('notice source and copy destination use selected mapped filesystem', () {
    final root = Directory.systemTemp.createTempSync('mapped-notice-artifact-');
    addTearDown(() => root.deleteSync(recursive: true));
    final fileSystem = FixtureMappedFileSystem(root);
    const input = '/selected-notices-source';
    const output = '/selected-notices-destination';
    final notices = FlutterNoticeArtifact(
      fileSystem: fileSystem,
      paths: p.Context(style: p.Style.posix),
    );
    final bytes = gzip.encode(utf8.encode('selected license'));
    fileSystem.file('$input/NOTICES.Z')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    fileSystem.directory(output).createSync();
    fileSystem.touched.clear();
    notices.copy(
      sourceFlutterAssetsDirectory: input,
      destinationFlutterAssetsDirectory: output,
    );
    expect(fileSystem.file('$output/NOTICES.Z').readAsBytesSync(), bytes);
    expect(fileSystem.touched, contains('$input/NOTICES.Z'));
    expect(fileSystem.touched, contains('$output/NOTICES.Z'));
    expect(File('$output/NOTICES.Z').existsSync(), isFalse);
    expect(
      () => notices.copy(
        sourceFlutterAssetsDirectory: '/selected-notices-missing',
        destinationFlutterAssetsDirectory: output,
      ),
      throwsA(isA<FlutterBuildError>()),
    );
    expect(fileSystem.file('$output/NOTICES.Z').readAsBytesSync(), bytes);
  });
}
