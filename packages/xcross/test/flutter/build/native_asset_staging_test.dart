import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

import '../../host_operations_fixtures.dart';
import 'macho_linkedit_aligner_test.dart';
import 'support/native_asset_framework_fixtures.dart';

void main() {
  late Directory temporary;
  late FixtureMappedFileSystem mapped;
  late NativeAssetFrameworks<LinuxHost> frameworks;
  late String output;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('native_asset_staging-');
    mapped = FixtureMappedFileSystem(temporary);
    output = '/xcross-framework-fixture/assemble';
    final host = LinuxHost(fileSystem: mapped);
    frameworks = nativeFrameworkService(fixtureRunner(host, log: fixtureLog()));
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test(
    testOn: '!windows',
    'staging isolates repairs from the original hook output',
    () async {
      final source = mapped.directory(
        p.join(output, 'native_assets', 'Asset.framework'),
      )..createSync(recursive: true);
      mapped.file(p.join(source.path, 'Asset')).writeAsStringSync('original');
      final staged = await frameworks.stage([source.path], output);
      expect(staged, [
        p.join(output, 'xcross_staged_frameworks', 'Asset.framework'),
      ]);
      mapped.file(p.join(staged.single, 'Asset')).writeAsStringSync('repaired');
      expect(
        mapped.file(p.join(source.path, 'Asset')).readAsStringSync(),
        'original',
      );
    },
  );

  test(
    'constructor rejects mismatched filesystem, context and copier ports',
    () {
      final host = LinuxHost(fileSystem: mapped);
      final runner = fixtureRunner(host, log: fixtureLog());
      final other = LinuxHost();
      NativeAssetFrameworks<LinuxHost> create({
        HostFileSystemInterface? fileSystem,
        p.Context? paths,
        RecursiveDirectoryCopier? copier,
      }) => NativeAssetFrameworks(
        fileSystem: fileSystem ?? host.fileSystem,
        paths: paths ?? host.paths.context,
        runner: runner,
        copier:
            copier ??
            RecursiveDirectoryCopier(
              fileSystem: host.fileSystem,
              paths: host.paths.context,
            ),
      );
      expect(create, returnsNormally);
      expect(() => create(fileSystem: other.fileSystem), throwsArgumentError);
      expect(() => create(paths: other.paths.context), throwsArgumentError);
      expect(
        () => create(
          copier: RecursiveDirectoryCopier(
            fileSystem: other.fileSystem,
            paths: host.paths.context,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => create(
          copier: RecursiveDirectoryCopier(
            fileSystem: host.fileSystem,
            paths: other.paths.context,
          ),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'rejects cyclic and chained escaping links before replacing prior stage',
    () async {
      final prior =
          mapped.file(p.join(output, 'xcross_staged_frameworks', 'prior'))
            ..createSync(recursive: true)
            ..writeAsStringSync('retained');
      final outside = mapped.directory('/xcross-framework-fixture/hook_output')
        ..createSync(recursive: true);
      mapped
          .file(p.join(outside.path, 'payload'))
          .writeAsStringSync('original');
      for (final cyclic in [false, true]) {
        final source = mapped.directory(
          p.join(
            output,
            'native_assets',
            '${cyclic ? 'Cyclic' : 'Chained'}.framework',
          ),
        )..createSync(recursive: true);
        final portal = mapped.link(p.join(source.path, 'Portal'));
        final binary = mapped.link(p.join(source.path, 'Binary'));
        try {
          portal.createSync(cyclic ? 'Binary' : '../../../hook_output');
          binary.createSync(cyclic ? 'Portal' : 'Portal/payload');
        } on FileSystemException {
          markTestSkipped('host cannot create symlink fixtures');
          return;
        }
        await expectLater(
          frameworks.stage([source.path], output),
          throwsA(isA<FlutterBuildError>()),
        );
        expect(prior.readAsStringSync(), 'retained');
        expect(
          mapped.file(p.join(outside.path, 'payload')).readAsStringSync(),
          'original',
        );
      }
    },
  );

  test(
    testOn: '!windows',

    'mapped root and ancestor aliases stage safe versioned links before repair',
    () async {
      const source = '/xcross-framework-fixture/originals/Versioned.framework';
      final version = mapped.directory(p.join(source, 'Versions', 'A'))
        ..createSync(recursive: true);
      final original = mapped.file(p.join(version.path, 'Versioned'));
      final bytes = buildMachO(
        indirectCount: 3,
        strings: stringTable('_hello', padding: 8),
      );
      original.writeAsBytesSync(bytes);
      mapped
          .directory('/xcross-framework-fixture/aliases')
          .createSync(recursive: true);
      try {
        mapped.link(p.join(source, 'Versions', 'Current')).createSync('A');
        mapped
            .link(p.join(source, 'Versioned'))
            .createSync(p.join('Versions', 'Current', 'Versioned'));
        mapped
            .link('/xcross-framework-fixture/aliases/Versioned.framework')
            .createSync('../originals/Versioned.framework');
        mapped
            .link('/xcross-framework-fixture/ancestor')
            .createSync('originals');
      } on FileSystemException {
        markTestSkipped('host cannot create symlink fixtures');
        return;
      }
      for (final alias in [
        '/xcross-framework-fixture/aliases/Versioned.framework',
        '/xcross-framework-fixture/ancestor/Versioned.framework',
      ]) {
        final staged = await frameworks.stage([alias], output);
        expect(staged, [
          p.join(output, 'xcross_staged_frameworks', 'Versioned.framework'),
        ]);
        await frameworks.align(staged);
        final repaired = mapped
            .file(p.join(staged.single, 'Versioned'))
            .readAsBytesSync();
        expect(readSymtab(repaired).offset % 8, 0);
        expect(original.readAsBytesSync(), bytes);
        expect(
          mapped
              .link(p.join(staged.single, 'Versions', 'Current'))
              .targetSync(),
          'A',
        );
        expect(
          mapped.link(p.join(staged.single, 'Versioned')).targetSync(),
          p.join('Versions', 'Current', 'Versioned'),
        );
      }
    },
  );

  test(
    testOn: '!windows',
    'stages framework-relative links and rejects escaping links',
    () async {
      final source = mapped.directory(
        p.join(output, 'native_assets', 'Versioned.framework'),
      );
      final versionA = mapped.directory(p.join(source.path, 'Versions', 'A'))
        ..createSync(recursive: true);
      mapped
          .file(p.join(versionA.path, 'Versioned'))
          .writeAsStringSync('original');
      try {
        mapped.link(p.join(source.path, 'Versions', 'Current')).createSync('A');
        mapped
            .link(p.join(source.path, 'Versioned'))
            .createSync(p.join('Versions', 'Current', 'Versioned'));
      } on FileSystemException {
        markTestSkipped('host cannot create symlink fixtures');
        return;
      }
      final staged = await frameworks.stage([source.path], output);
      final stagedBinary = mapped.file(p.join(staged.single, 'Versioned'));
      expect(stagedBinary.readAsStringSync(), 'original');
      stagedBinary.writeAsStringSync('repaired');
      expect(
        mapped.file(p.join(versionA.path, 'Versioned')).readAsStringSync(),
        'original',
      );

      final outside =
          mapped.file(p.join(p.dirname(output), 'hook_output', 'Escaped'))
            ..createSync(recursive: true)
            ..writeAsStringSync('original');
      for (final (name, target) in [
        ('Relative', p.join('..', '..', '..', 'hook_output', 'Escaped')),
        ('Absolute', outside.path),
        ('Dangling', 'Missing'),
      ]) {
        final unsafe = mapped.directory(
          p.join(output, 'native_assets', '$name.framework'),
        )..createSync(recursive: true);
        final link = mapped.link(p.join(unsafe.path, name))..createSync(target);
        await expectLater(
          frameworks.stage([unsafe.path], output),
          throwsA(
            isA<FlutterBuildError>().having(
              (e) => e.message,
              'message',
              contains('Unsafe native asset framework symlink'),
            ),
          ),
        );
        link.deleteSync();
      }
      expect(outside.readAsStringSync(), 'original');
    },
  );
}
