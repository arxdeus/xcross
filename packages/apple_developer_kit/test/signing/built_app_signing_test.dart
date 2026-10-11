import 'dart:io';

import 'package:apple_developer_kit/shared/signing/bundle_signer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/host_services.dart';
import '../support/signing_fixture.dart';

/// Signs a real xcross-built `.app` with a throwaway identity.
///
/// `xcross flutter build` and simulator runs never sign, so the device-only
/// `Signing app` step had no CI coverage: an app that builds and runs on the
/// simulator could still be unsignable for a device (#118). Integration CI
/// points `XCROSS_SIGN_APP` at its build output, which is either a `.app` or a
/// directory holding exactly one. Unset, the test is skipped.
void main() {
  final target = Platform.environment['XCROSS_SIGN_APP'];

  test(
    'signs a built app bundle like a device run does',
    () async {
      final source = _findApp(target!);
      final temporary = Directory.systemTemp.createTempSync('xcross-sign-');
      addTearDown(() => temporary.deleteSync(recursive: true));
      // Signing rewrites the bundle in place, so work on a copy.
      final app = p.join(temporary.path, p.basename(source));
      await _copy(source, app);

      final asset = await createTestSigningAsset(
        temporary,
        'identity',
        'TESTTEAM123.*',
        hostServices: testHostServices,
      );
      final signer = BundleSigner(asset, hostServices: testHostServices);
      await signer.signApp(app);

      // The app and every embedded framework and extension must be sealed.
      final bundles = [
        app,
        for (final entity in Directory(
          app,
        ).listSync(recursive: true, followLinks: false))
          if (entity is Directory &&
              (entity.path.endsWith('.framework') ||
                  entity.path.endsWith('.appex')))
            entity.path,
      ];
      for (final bundle in bundles) {
        expect(
          File(p.join(bundle, '_CodeSignature', 'CodeResources')).existsSync(),
          isTrue,
          reason: '${p.relative(bundle, from: app)} was not sealed',
        );
      }
      stdout.writeln(
        'Signed ${p.basename(source)} and ${bundles.length - 1} nested '
        'bundles.',
      );
    },
    skip: target == null || target.isEmpty
        ? 'Set XCROSS_SIGN_APP to a built .app (or its parent directory).'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

String _findApp(String target) {
  final normalized = p.normalize(p.absolute(target));
  if (normalized.endsWith('.app')) return normalized;
  final apps = Directory(normalized)
      .listSync(followLinks: false)
      .whereType<Directory>()
      .where((directory) => directory.path.endsWith('.app'))
      .toList();
  if (apps.length != 1) {
    throw StateError('Expected one .app in $normalized, found ${apps.length}.');
  }
  return apps.single.path;
}

/// Copies [source] to [destination], keeping symlinks as symlinks so the
/// signer sees the bundle exactly as built.
Future<void> _copy(String source, String destination) async {
  Directory(destination).createSync(recursive: true);
  await for (final entity in Directory(
    source,
  ).list(recursive: true, followLinks: false)) {
    final target = p.join(destination, p.relative(entity.path, from: source));
    switch (entity) {
      case Link():
        Link(target).createSync(entity.targetSync(), recursive: true);
      case Directory():
        Directory(target).createSync(recursive: true);
      case File():
        File(target).parent.createSync(recursive: true);
        entity.copySync(target);
    }
  }
}
