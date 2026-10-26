// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'auth_command.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

AuthArgs _$parseAuthArgsResult(ArgResults result) => AuthArgs()
  ..issuerId = result['issuer-id'] as String?
  ..issuerIdWasParsed = result.wasParsed('issuer-id')
  ..keyId = result['key-id'] as String?
  ..keyIdWasParsed = result.wasParsed('key-id')
  ..privateKey = result['private-key'] as String?
  ..privateKeyWasParsed = result.wasParsed('private-key')
  ..appleId = result['apple-id'] as String?
  ..appleIdWasParsed = result.wasParsed('apple-id')
  ..password = result['password'] as String?
  ..adiLibraryDir = result['adi-library-dir'] as String?
  ..adiLibraryDirWasParsed = result.wasParsed('adi-library-dir')
  ..anisetteUrl = result['anisette-url'] as String?
  ..anisetteUrlWasParsed = result.wasParsed('anisette-url');

ArgParser _$populateAuthArgsParser(ArgParser parser) => parser
  ..addOption(
    'issuer-id',
    help: 'App Store Connect API "Issuer ID" (one per team).',
  )
  ..addOption(
    'key-id',
    help: 'The API key\'s "Key ID", shown next to it in App Store Connect.',
  )
  ..addOption(
    'private-key',
    help: 'Path to the downloaded AuthKey_<keyId>.p8 file.',
  )
  ..addOption(
    'apple-id',
    help: 'Use Apple ID/password login. If omitted, xcross prompts.',
    valueHelp: 'email',
  )
  ..addOption(
    'password',
    help: 'Apple ID password (optional; prompted if omitted).',
  )
  ..addOption(
    'adi-library-dir',
    help:
        'Legacy: sign in with local Android ADI libraries from this '
        'directory (libCoreADI.so / libstoreservicescore.so). Apple '
        'currently rejects that identity (-80046); prefer the default '
        'Omnisette path. Matching x64 or ARM64 libraries are fetched '
        'from the Apple Music APK when missing.',
    valueHelp: 'path',
  )
  ..addOption(
    'anisette-url',
    help:
        'Omnisette Mac-anisette server for Apple ID login. Defaults to '
        'https://mac-ani.jkcoxson.com. Any omnisette-server v3 '
        'deployment works (self-hosted or public). Can also be set with '
        'XCROSS_ANISETTE_URL. Mutually exclusive with --adi-library-dir.',
    valueHelp: 'url',
  );

final _$parserForAuthArgs = _$populateAuthArgsParser(ArgParser());

AuthArgs parseAuthArgs(List<String> args) {
  final result = _$parserForAuthArgs.parse(args);
  return _$parseAuthArgsResult(result);
}
