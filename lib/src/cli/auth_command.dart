import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:provision_dart/provision_dart.dart' show AdiLibraryFetcher;
import 'package:xcross/src/appstoreconnect/asc_config.dart';
import 'package:xcross/src/appstoreconnect/developer_services_client.dart';
import 'package:xcross/src/grandslam/anisette/anisette_data_provider.dart';
import 'package:xcross/src/grandslam/anisette/anisette_provider.dart';
import 'package:xcross/src/grandslam/anisette/anisette_state.dart';
import 'package:xcross/src/grandslam/anisette/aoskit_anisette_provider.dart';
import 'package:xcross/src/grandslam/app_token_exchange.dart';
import 'package:xcross/src/grandslam/grandslam_login.dart';
import 'package:xcross/src/grandslam/grandslam_session_store.dart';
import 'package:xcross/src/util/apple_http_client.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// `xcross auth` — save credentials for the native (no-Swift) signing
/// pipeline. Supports both App Store Connect API keys and Apple ID/password
/// GrandSlam login.
class AuthCommand extends Command<void> {
  AuthCommand() {
    argParser
      ..addOption(
        'issuer-id',
        help: 'App Store Connect API "Issuer ID" (one per team).',
      )
      ..addOption(
        'key-id',
        help:
            "The API key's \"Key ID\", shown next to it in App Store Connect.",
      )
      ..addOption(
        'private-key',
        help: 'Path to the downloaded AuthKey_<keyId>.p8 file.',
      )
      ..addOption(
        'apple-id',
        valueHelp: 'email',
        help: 'Use Apple ID/password login. If omitted, xcross prompts.',
      )
      ..addOption(
        'adi-library-dir',
        valueHelp: 'path',
        help:
            'Linux: directory containing libCoreADI.so and '
            'libstoreservicescore.so for Apple ID login. Defaults to '
            '~/.config/xcross/adi-libs (fetched automatically on x86_64).',
      );
  }

  @override
  String get name => 'auth';

  @override
  String get description =>
      'Save App Store Connect API key credentials or sign in with Apple ID '
      'for the native (no-Swift) signing pipeline.';

  @override
  Future<void> run() async {
    final issuerId = argResults!.option('issuer-id');
    final keyId = argResults!.option('key-id');
    final privateKeyPath = argResults!.option('private-key');
    final appleId = argResults!.option('apple-id')?.trim();

    final ascValues = [issuerId, keyId, privateKeyPath];
    final hasAnyAsc = const [
      'issuer-id',
      'key-id',
      'private-key',
    ].any(argResults!.wasParsed);
    final hasAllAsc = ascValues.every(_present);
    if (hasAnyAsc) {
      if (argResults!.wasParsed('apple-id')) {
        throw XcrossError(
          'Use either App Store Connect API key flags or --apple-id, not both.',
        );
      }
      if (!hasAllAsc) {
        throw XcrossError(
          'Provide non-empty values for all of --issuer-id, --key-id, and '
          '--private-key, or none to use Apple ID login.',
        );
      }
      if (argResults!.wasParsed('adi-library-dir')) {
        throw XcrossError('--adi-library-dir only applies to Apple ID login.');
      }
      await _saveAscCredentials(
        issuerId: issuerId!,
        keyId: keyId!,
        privateKeyPath: privateKeyPath!,
      );
      return;
    }

    if (argResults!.wasParsed('apple-id') && !_present(appleId)) {
      throw XcrossError('--apple-id requires a non-empty email address.');
    }
    await _runAppleIdLogin(initialUsername: _present(appleId) ? appleId : null);
  }

  Future<void> _saveAscCredentials({
    required String issuerId,
    required String keyId,
    required String privateKeyPath,
  }) async {
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
    // Authentication mode is explicit: a newly saved ASC key should not be
    // silently shadowed by an older still-unexpired Apple ID session.
    await GrandSlamSessionStore().clear();

    Log.logDone('App Store Connect credentials saved to $configPath');
  }

  Future<void> _runAppleIdLogin({String? initialUsername}) async {
    if (!Platform.isWindows && !Platform.isLinux) {
      throw XcrossError(
        'Built-in Apple ID/password login is available on Linux and Windows. '
        'On this platform use App Store Connect API key flags.',
      );
    }
    if (Platform.isWindows && argResults!.wasParsed('adi-library-dir')) {
      throw XcrossError(
        '--adi-library-dir is Linux-only. On Windows, Apple ID login uses '
        'the bundled AOSKit helper with website-edition iTunes/iCloud.',
      );
    }

    final resolved = Platform.isWindows
        ? await _windowsAnisette()
        : await _linuxAnisette();
    final anisette = resolved.anisette;
    final adiLibraryDirectory = resolved.adiLibraryDirectory;

    final username = initialUsername ?? _readRequiredLine('Apple ID: ');
    final password = _readPassword();
    GrandSlamClient? loginClient;
    GrandSlamAppTokenExchange? tokenExchange;
    try {
      final endpoints = await Log.logStep(
        'Resolving GrandSlam endpoints',
        anisette.resolveGrandSlamEndpoints,
      );
      loginClient = GrandSlamClient(
        endpoints: endpoints,
        fetchAnisetteHeaders: anisette.fetchAnisetteHeaders,
      );
      final loginData = await Log.logStep(
        'Signing in with Apple ID',
        () => loginClient!.login(
          username: username,
          password: password,
          fetchTwoFactorCode: _promptTwoFactorCode,
        ),
      );
      tokenExchange = GrandSlamAppTokenExchange(
        endpoints: endpoints,
        fetchAnisetteHeaders: anisette.fetchAnisetteHeaders,
      );
      final token = await Log.logStep(
        'Fetching Developer Services session',
        () => tokenExchange!.exchange(loginData),
      );
      final teamHttpClient = createAppleHttpClient();
      final List<DeveloperServicesTeam> teams;
      try {
        teams = await Log.logStep(
          'Fetching Developer Services teams',
          () => DeveloperServicesClient.listTeams(
            token: token,
            fetchAnisetteHeaders: anisette.fetchAnisetteHeaders,
            httpClient: teamHttpClient,
          ),
        );
      } finally {
        teamHttpClient.close();
      }
      final activeTeams = teams
          .where((team) => team.status.toLowerCase() == 'active')
          .toList();
      if (activeTeams.isEmpty) {
        throw XcrossError('No active Developer Services teams are available.');
      }
      final team = activeTeams.length == 1
          ? activeTeams.single
          : _selectTeam(activeTeams);
      final store = GrandSlamSessionStore();
      await store.save(
        GrandSlamSession(
          username: username,
          token: token,
          teamId: team.id,
          adiLibraryDirectory: adiLibraryDirectory,
        ),
      );
      Log.logDone('Signed in as $username. Session saved to ${store.path}');
    } on XcrossError {
      rethrow;
    } on Object catch (e) {
      throw XcrossError('Apple ID login failed: $e');
    } finally {
      tokenExchange?.close();
      loginClient?.close();
      anisette.close();
    }
  }

  Future<({AnisetteProvider anisette, String? adiLibraryDirectory})>
  _windowsAnisette() async => (
    anisette: AosKitAnisetteProvider(),
    adiLibraryDirectory: null,
  );

  Future<({AnisetteProvider anisette, String? adiLibraryDirectory})>
  _linuxAnisette() async {
    final adiLibraryDir = await _resolveLinuxAdiLibraryDirectory();
    return (
      anisette: AnisetteDataProvider(adiLibraryDir),
      adiLibraryDirectory: adiLibraryDir,
    );
  }

  Future<String> _resolveLinuxAdiLibraryDirectory() async {
    final configured = argResults!.option('adi-library-dir');
    final adiLibraryDir =
        configured ??
        p.join(p.dirname(AnisetteStateStore.defaultPath()), 'adi-libs');
    if (_adiLibsPresent(adiLibraryDir)) {
      return Directory(adiLibraryDir).absolute.path;
    }

    if (configured != null) {
      _throwMissingAdiLibs(adiLibraryDir);
    }

    if (Abi.current() != Abi.linuxX64) {
      throw XcrossError(
        'Apple ID login on ${Abi.current()} needs matching ADI libraries at '
        '"$adiLibraryDir" (libCoreADI.so and libstoreservicescore.so). '
        'Extract them from the Apple Music Android APK for this architecture, '
        'or pass --adi-library-dir.',
      );
    }

    await Log.logStep(
      'Fetching Apple ADI libraries',
      () => AdiLibraryFetcher(
        cacheDir: Directory(adiLibraryDir),
      ).ensureLibraries(),
    );
    if (!_adiLibsPresent(adiLibraryDir)) {
      _throwMissingAdiLibs(adiLibraryDir);
    }
    return Directory(adiLibraryDir).absolute.path;
  }

  DeveloperServicesTeam _selectTeam(List<DeveloperServicesTeam> teams) {
    stdout.writeln('Multiple teams available. Choose one:');
    for (var i = 0; i < teams.length; i++) {
      stdout.writeln('  [${i + 1}] ${teams[i].name} (${teams[i].id})');
    }
    while (true) {
      stdout.write('Choice (1-${teams.length}): ');
      final raw = stdin.readLineSync()?.trim();
      if (raw == null) {
        throw XcrossError('No team selection made (stdin closed).');
      }
      final choice = int.tryParse(raw);
      if (choice != null && choice >= 1 && choice <= teams.length) {
        return teams[choice - 1];
      }
      stdout.writeln(
        'Invalid choice "$raw". Enter a number 1-${teams.length}.',
      );
    }
  }

  Future<String?> _promptTwoFactorCode(GrandSlamTwoFactorMode mode) async {
    Log.stopStep();
    final prompt = switch (mode) {
      GrandSlamTwoFactorMode.sms =>
        'Enter the verification code sent via SMS: ',
      GrandSlamTwoFactorMode.trustedDevice =>
        'Enter the verification code sent to your trusted device: ',
      GrandSlamTwoFactorMode.unspecified => 'Enter the verification code: ',
    };
    return _readHiddenLine(prompt, valueName: 'verification code')?.trim();
  }

  String _readRequiredLine(String prompt) {
    stdout.write(prompt);
    final value = stdin.readLineSync()?.trim();
    if (!_present(value)) throw XcrossError('No value entered for $prompt');
    return value!;
  }

  String _readPassword() {
    final password = _readHiddenLine('Password: ', valueName: 'password');
    if (!_present(password)) throw XcrossError('No password entered.');
    return password!;
  }

  String? _readHiddenLine(String prompt, {required String valueName}) {
    if (!stdin.hasTerminal) {
      throw XcrossError('$valueName prompt requires an interactive terminal.');
    }

    final bool priorEcho;
    final bool priorLine;
    try {
      priorEcho = stdin.echoMode;
      priorLine = stdin.lineMode;
    } on Object catch (e) {
      throw XcrossError('Secure $valueName input is unavailable: $e');
    }

    try {
      try {
        stdin.echoMode = false;
        stdin.lineMode = true;
      } on Object catch (e) {
        throw XcrossError(
          'Could not disable terminal echo; refusing to read the $valueName: $e',
        );
      }
      stdout.write(prompt);
      final value = stdin.readLineSync();
      stdout.writeln();
      return _present(value) ? value : null;
    } finally {
      _trySet(() => stdin.lineMode = priorLine);
      _trySet(() => stdin.echoMode = priorEcho);
    }
  }

  static bool _adiLibsPresent(String dir) => const [
    'libCoreADI.so',
    'libstoreservicescore.so',
  ].every((name) => File(p.join(dir, name)).existsSync());

  static Never _throwMissingAdiLibs(String dir) {
    throw XcrossError(
      'Apple ID login needs ADI libraries at "$dir" '
      '(libCoreADI.so and/or libstoreservicescore.so missing). Place both '
      'there, or pass --adi-library-dir.',
    );
  }

  static bool _present(String? value) => value != null && value.isNotEmpty;

  static void _trySet(void Function() f) {
    try {
      f();
    } catch (_) {}
  }
}
