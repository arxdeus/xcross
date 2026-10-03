import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/auth_command.dart';
import 'package:xcross/src/device/internal/signing_session.dart';

import 'runtime_fixture.dart';

void main() {
  group('xcross auth clear', () {
    test('covers every store the auth and signing flows write', () {
      final configDirectory = testRuntime().appleHostServices.configDirectory;
      final paths = AuthCommand.authArtifacts(
        configDirectory,
      ).map((entity) => entity.path);

      expect(
        paths,
        containsAll(<String>[
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
        ]),
      );
    });

    test('never reaches outside the config directory', () {
      for (final artifact in AuthCommand.authArtifacts(
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
      final names = AuthCommand.authArtifacts(
        p.join('config', 'xcross'),
      ).map((entity) => p.basename(entity.path));

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

        final removed = await AuthCommand.deleteAuthArtifacts(root.path);

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

      expect(await AuthCommand.deleteAuthArtifacts(root.path), isEmpty);
    });
  });
}
