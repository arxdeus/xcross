import 'package:test/test.dart';
import 'package:xcross/src/signing/zsign_cli.dart';

void main() {
  test('signs an app directory in place without requesting an IPA archive', () {
    final args = buildZsignArguments(
      appOrIpaPath: 'Runner.app',
      privateKeyPemPath: 'key.pem',
      certificatePemPath: 'cert.pem',
      provisioningProfilePath: 'profile.mobileprovision',
      isAppDirectory: true,
    );

    expect(args, isNot(contains('-o')));
    expect(args, isNot(contains('-z')));
    expect(args.last, 'Runner.app');
  });

  test('keeps archive output arguments for an IPA', () {
    final args = buildZsignArguments(
      appOrIpaPath: 'input.ipa',
      privateKeyPemPath: 'key.pem',
      certificatePemPath: 'cert.pem',
      provisioningProfilePath: 'profile.mobileprovision',
      isAppDirectory: false,
      outputPath: 'output.ipa',
      zipLevel: 6,
    );

    expect(args, containsAllInOrder(['-o', 'output.ipa', '-z', '6']));
  });
}
