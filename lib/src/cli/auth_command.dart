import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:xcross/src/appstoreconnect/asc_config.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// `xcross auth` — save App Store Connect API key credentials, used by the
/// native (no-Swift) signing pipeline (`NativeBackend`) wherever the `xtool`
/// binary isn't available (Windows today). The direct equivalent of
/// `xtool auth --mode key` for the native path — see `AscCredentials`.
class AuthCommand extends Command<void> {
  AuthCommand() {
    argParser
      ..addOption(
        'issuer-id',
        help: 'App Store Connect API "Issuer ID" (one per team).',
        mandatory: true,
      )
      ..addOption(
        'key-id',
        help:
            "The API key's \"Key ID\", shown next to it in App Store Connect.",
        mandatory: true,
      )
      ..addOption(
        'private-key',
        help: 'Path to the downloaded AuthKey_<keyId>.p8 file.',
        mandatory: true,
      );
  }

  @override
  String get name => 'auth';

  @override
  String get description =>
      'Save App Store Connect API key credentials for the native '
      '(no-Swift) signing pipeline.';

  @override
  Future<void> run() async {
    final issuerId = argResults!.option('issuer-id')!;
    final keyId = argResults!.option('key-id')!;
    final privateKeyPath = argResults!.option('private-key')!;

    final keyFile = File(privateKeyPath);
    if (!keyFile.existsSync()) {
      throw XcrossError('No file found at "$privateKeyPath".');
    }

    final configPath = AscCredentials.defaultConfigPath();
    final configFile = File(configPath);
    await configFile.parent.create(recursive: true);
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'issuerId': issuerId,
        'keyId': keyId,
        'privateKeyPath': keyFile.absolute.path,
      }),
    );

    Log.logDone('App Store Connect credentials saved to $configPath');
  }
}
