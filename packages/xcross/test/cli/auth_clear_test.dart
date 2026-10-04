import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/device/internal/signing_session.dart';

import 'auth_fixture.dart';
import 'runtime_fixture.dart';

void main() {
  group('xcross auth clear', () {
    for (final style in [p.Style.posix, p.Style.windows]) {
      test('clear uses selected logical namespace on $style', () async {
        final fixture = AuthNamespaceFixture(style: style);
        addTearDown(fixture.dispose);
        final directory = fixture.services.configDirectory;
        final command = authFixture(services: fixture.services);
        final artifacts = command.authArtifacts(directory);
        for (final artifact in artifacts.take(4)) {
          artifact.parent.createSync(recursive: true);
          (artifact as File).writeAsStringSync('fixture');
        }
        for (final artifact in artifacts.skip(4)) {
          (artifact as Directory).createSync(recursive: true);
        }
        final keep = fixture.fileSystem.file(
          fixture.paths.context.join(directory, 'update_check.json'),
        )..writeAsStringSync('{}');
        fixture.fileSystem.acquisitions.clear();
        expect(await command.deleteAuthArtifacts(directory), [
          'appstoreconnect.json',
          'grandslam-session.json',
          'anisette-state.json',
          'local.key',
          'adi',
          'signing',
        ]);
        expect(fixture.fileSystem.acquisitions, hasLength(6));
        expect(keep.existsSync(), isTrue);
        expect(artifacts.every((artifact) => !artifact.existsSync()), isTrue);
      });

      test(
        'ASC key path stays logical after selected save on $style',
        () async {
          final fixture = AuthNamespaceFixture(style: style);
          addTearDown(fixture.dispose);
          final keyPath = fixture.path('AuthKey_fixture.p8');
          fixture.fileSystem.file(keyPath).writeAsStringSync('fixture pem');
          final command = authFixture(services: fixture.services);
          final runner = CommandRunner<void>('fixture', 'fixture')
            ..addCommand(command);
          await runner.run([
            'auth',
            '--issuer-id',
            'issuer',
            '--key-id',
            'key-id',
            '--private-key',
            'AuthKey_fixture.p8',
          ]);
          final logicalConfig = AscCredentials.defaultConfigPath(
            hostServices: fixture.services,
          );
          final saved =
              jsonDecode(
                    fixture.fileSystem.file(logicalConfig).readAsStringSync(),
                  )
                  as Map<String, dynamic>;
          expect(saved['privateKeyPath'], keyPath);
          final credentials = await AscCredentialsLoader(
            hostServices: fixture.services,
          ).load();
          expect(await credentials.readPrivateKeyPem(), 'fixture pem');
          expect(fixture.fileSystem.acquisitions, contains(keyPath));
        },
      );
    }

    test('covers every store the auth and signing flows write', () {
      final configDirectory = testRuntime().appleHostServices.configDirectory;
      final paths = authFixture()
          .authArtifacts(configDirectory)
          .map((entity) => p.normalize(entity.path));

      expect(
        paths,
        containsAll(
          <String>[
            AscCredentials.defaultConfigPath(
              hostServices: testRuntime().appleHostServices,
            ),
            GrandSlamSessionStore.defaultPath(
              hostServices: testRuntime().appleHostServices,
            ),
            AnisetteStateStore.defaultPath(
              hostServices: testRuntime().appleHostServices,
            ),
            LocalCipher.defaultKeyFilePath(
              hostServices: testRuntime().appleHostServices,
            ),
            AnisetteStateStore(
              hostServices: testRuntime().appleHostServices,
            ).provisioningDirectory,
            SigningSession.signingRoot(configDirectory),
          ].map(p.normalize),
        ),
      );
    });

    test('never reaches outside the config directory', () {
      for (final artifact in authFixture().authArtifacts(
        p.join('config', 'xcross'),
      )) {
        expect(
          p.isWithin(p.join('config', 'xcross'), artifact.path),
          isTrue,
          reason: artifact.path,
        );
      }
    });

    test('spares config state that identifies no account', () {
      final names = authFixture()
          .authArtifacts(p.join('config', 'xcross'))
          .map((entity) => p.basename(entity.path));

      expect(names, isNot(contains('update_check.json')));
      expect(names, isNot(contains('adi-libs')));
    });

    test(
      'removes credentials and whole signing trees, reporting each',
      () async {
        final root = await Directory.systemTemp.createTemp('xcross_auth_clear');
        addTearDown(() => root.delete(recursive: true));

        final session = File(p.join(root.path, 'grandslam-session.json'))
          ..writeAsStringSync('{}');
        final certificate = File(
          p.join(
            SigningSession.identityDirFor(root.path, 'developer-services-TEAM'),
            'certificate.pem',
          ),
        );
        certificate.parent.createSync(recursive: true);
        certificate.writeAsStringSync('pem');
        final keep = File(p.join(root.path, 'update_check.json'))
          ..writeAsStringSync('{}');

        final removed = await authFixture().deleteAuthArtifacts(root.path);

        expect(
          removed,
          containsAll(<String>['grandslam-session.json', 'signing']),
        );
        expect(session.existsSync(), isFalse);
        expect(certificate.existsSync(), isFalse);
        expect(
          Directory(SigningSession.signingRoot(root.path)).existsSync(),
          isFalse,
        );
        expect(keep.existsSync(), isTrue);
      },
    );

    test('reports nothing for an untouched config directory', () async {
      final root = await Directory.systemTemp.createTemp('xcross_auth_clear');
      addTearDown(() => root.delete(recursive: true));

      expect(await authFixture().deleteAuthArtifacts(root.path), isEmpty);
    });
  });
}
