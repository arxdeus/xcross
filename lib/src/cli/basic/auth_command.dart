import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';

part 'auth_command.g.dart';

/// Options for `xcross auth`.
@CliOptions(createCommand: true)
final class AuthArgs {
  @CliOption(help: 'App Store Connect API "Issuer ID" (one per team).')
  late String? issuerId;

  late bool issuerIdWasParsed;

  @CliOption(
    help: "The API key's \"Key ID\", shown next to it in App Store Connect.",
  )
  late String? keyId;

  late bool keyIdWasParsed;

  @CliOption(help: 'Path to the downloaded AuthKey_<keyId>.p8 file.')
  late String? privateKey;

  late bool privateKeyWasParsed;

  @CliOption(
    valueHelp: 'email',
    help: 'Use Apple ID/password login. If omitted, xcross prompts.',
  )
  late String? appleId;

  late bool appleIdWasParsed;

  @CliOption(help: 'Apple ID password (optional; prompted if omitted).')
  late String? password;

  @CliOption(
    valueHelp: 'path',
    help:
        'Directory containing libCoreADI.so and '
        'libstoreservicescore.so for Apple ID login. Defaults to '
        'the xcross config adi-libs directory. On x86_64, missing libs '
        'are fetched from the Apple Music APK.',
  )
  late String? adiLibraryDir;

  late bool adiLibraryDirWasParsed;
}

const _adiLibraryNames = ['libCoreADI.so', 'libstoreservicescore.so'];

/// `xcross auth` — save credentials for the native (no-Swift) signing
/// pipeline. Supports both App Store Connect API keys and Apple ID/password
/// GrandSlam login.
final class AuthCommand extends _$AuthArgsCommand<void> {
  @override
  String get name => 'auth';

  @override
  String get description =>
      'Save App Store Connect API key credentials or sign in with Apple ID '
      'for the native (no-Swift) signing pipeline.';

  @override
  Future<void> run() {
    final usesAscKey =
        _options.issuerIdWasParsed ||
        _options.keyIdWasParsed ||
        _options.privateKeyWasParsed;
    return usesAscKey ? _saveAscCredentials() : _appleIdLogin();
  }

  // ---------------------------------------------------------------- ASC key

  Future<void> _saveAscCredentials() async {
    if (_options.appleIdWasParsed) {
      throw XcrossError(
        'Use either App Store Connect API key flags or --apple-id, not both.',
      );
    }
    final issuerId = _options.issuerId;
    final keyId = _options.keyId;
    final privateKeyPath = _options.privateKey;
    if (![issuerId, keyId, privateKeyPath].every(_present)) {
      throw XcrossError(
        'Provide non-empty values for all of --issuer-id, --key-id, and '
        '--private-key, or none to use Apple ID login.',
      );
    }
    if (_options.adiLibraryDirWasParsed) {
      throw XcrossError('--adi-library-dir only applies to Apple ID login.');
    }

    final keyFile = File(privateKeyPath!);
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

  // --------------------------------------------------------------- Apple ID

  Future<void> _appleIdLogin() async {
    final appleId = _options.appleId?.trim();
    if (_options.appleIdWasParsed && !_present(appleId)) {
      throw XcrossError('--apple-id requires a non-empty email address.');
    }
    if (!Platform.isWindows && !Platform.isLinux) {
      throw XcrossError(
        'Built-in Apple ID/password login is available on Linux and Windows. '
        'On this platform use App Store Connect API key flags.',
      );
    }

    // Credentials before any await: keeps interactive stdin simple on Windows.
    final username = _present(appleId)
        ? appleId!
        : _readRequiredLine('Apple ID: ');
    final givenPassword = _options.password;
    final password = _present(givenPassword)
        ? givenPassword
        : _readHiddenLine('Password: ', valueName: 'password');
    if (password == null || password.isEmpty) {
      throw XcrossError('No password entered.');
    }

    final adiLibraryDirectory = await _resolveAdiLibraryDirectory();
    final anisette = AnisetteDataProvider(adiLibraryDirectory);
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
      final team = await _selectActiveTeam(token, anisette);

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
    } on Object catch (e, st) {
      Log.logError('Apple ID login failed: $e');
      Log.logTrace('$st');
      throw XcrossError('Apple ID login failed: $e');
    } finally {
      tokenExchange?.close();
      loginClient?.close();
      anisette.close();
    }
  }

  Future<DeveloperServicesTeam> _selectActiveTeam(
    DeveloperServicesLoginToken token,
    AnisetteProvider anisette,
  ) async {
    final httpClient = AppleHttp.createAppleHttpClient();
    final List<DeveloperServicesTeam> teams;
    try {
      teams = await Log.logStep(
        'Fetching Developer Services teams',
        () => DeveloperServicesClient.listTeams(
          token: token,
          fetchAnisetteHeaders: anisette.fetchAnisetteHeaders,
          httpClient: httpClient,
        ),
      );
    } finally {
      httpClient.close();
    }

    final active = teams
        .where((team) => team.status.toLowerCase() == 'active')
        .toList();
    return switch (active) {
      [] => throw XcrossError(
        'No active Developer Services teams are available.',
      ),
      [final only] => only,
      _ => _promptForTeam(active),
    };
  }

  DeveloperServicesTeam _promptForTeam(List<DeveloperServicesTeam> teams) {
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
    return _readRequiredLine(switch (mode) {
      GrandSlamTwoFactorMode.sms =>
        'Enter the verification code sent via SMS: ',
      GrandSlamTwoFactorMode.trustedDevice =>
        'Enter the verification code sent to your trusted device: ',
      GrandSlamTwoFactorMode.unspecified => 'Enter the verification code: ',
    });
  }

  // ------------------------------------------------------------- ADI libs

  Future<String> _resolveAdiLibraryDirectory() async {
    final configured = _options.adiLibraryDir;
    final adiLibraryDir =
        configured ??
        p.join(p.dirname(AnisetteStateStore.defaultPath()), 'adi-libs');
    if (_adiLibsPresent(adiLibraryDir)) {
      return Directory(adiLibraryDir).absolute.path;
    }
    if (configured != null) {
      _throwMissingAdiLibs(adiLibraryDir);
    }

    final abi = Abi.current();
    if (abi != Abi.linuxX64 && abi != Abi.windowsX64) {
      throw XcrossError(
        'Apple ID login on $abi needs matching ADI libraries at '
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

  static bool _adiLibsPresent(String dir) =>
      _adiLibraryNames.every((name) => File(p.join(dir, name)).existsSync());

  static Never _throwMissingAdiLibs(String dir) {
    throw XcrossError(
      'Apple ID login needs ADI libraries at "$dir" '
      '(libCoreADI.so and/or libstoreservicescore.so missing). Place both '
      'there, or pass --adi-library-dir.',
    );
  }

  // ------------------------------------------------------------ stdin input

  // Never call stdout/stderr.flush() without awaiting it. Unawaited flush
  // leaves the IOSink "bound to a stream" (dart-lang/sdk#25277), so the next
  // write throws — especially visible on Windows AOT (`dart build cli`).
  // readLineSync itself is fine; there is no stdin.readLine().

  String _readRequiredLine(String prompt) {
    stdout.write(prompt);
    final value = stdin.readLineSync()?.trim();
    if (!_present(value)) throw XcrossError('No value entered for $prompt');
    return value!;
  }

  String? _readHiddenLine(String prompt, {required String valueName}) {
    if (!stdin.hasTerminal) {
      throw XcrossError('$valueName prompt requires an interactive terminal.');
    }

    // Write before touching console modes.
    stdout.write(prompt);

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
        // Windows: lineMode must stay on while echoMode is toggled.
        stdin.lineMode = true;
        stdin.echoMode = false;
      } on Object catch (e) {
        throw XcrossError(
          'Could not disable terminal echo; refusing to read the $valueName: $e',
        );
      }
      final value = stdin.readLineSync();
      return _present(value) ? value : null;
    } finally {
      _trySet(() => stdin.echoMode = priorEcho);
      _trySet(() => stdin.lineMode = priorLine);
      stdout.writeln();
    }
  }

  static bool _present(String? value) => value != null && value.isNotEmpty;

  static void _trySet(void Function() f) {
    try {
      f();
    } catch (_) {}
  }
}
