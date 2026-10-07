@internal
library;

import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/host/shared/adi/loader/loader.dart';
import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/adi/apk_fetch.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/developer_services_team_discovery_client.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_data_provider.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_provider.dart';
import 'package:apple_developer_kit/shared/grandslam/app_token_exchange.dart';
import 'package:apple_developer_kit/shared/grandslam/grandslam_login.dart';
import 'package:apple_developer_kit/shared/grandslam/grandslam_session_store.dart';
import 'package:apple_developer_kit/shared/grandslam/grandslam_two_factor.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/cli/internal/parsed_command.dart';
import 'package:xcross/src/shared/errors/errors.dart';

part 'auth_command.g.dart';

/// Options for `xcross auth`.
@internal
@CliOptions()
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
        'the xcross config adi-libs directory. Matching x64 or ARM64 '
        'libraries are fetched from the Apple Music APK when missing.',
  )
  late String? adiLibraryDir;

  late bool adiLibraryDirWasParsed;
}

const _authOptionNames = [
  'issuer-id',
  'key-id',
  'private-key',
  'apple-id',
  'password',
  'adi-library-dir',
];

/// `xcross auth` — save credentials for the native (no-Swift) signing
/// pipeline. Supports both App Store Connect API keys and Apple ID/password
/// GrandSlam login.
@internal
final class AuthCommand extends ParsedCommand<AuthArgs, void> {
  @override
  ArgParser populateOptions(ArgParser parser) =>
      _$populateAuthArgsParser(parser);
  @override
  AuthArgs parseOptions(ArgResults results) => _$parseAuthArgsResult(results);

  AuthCommand({
    required this.log,
    required this.commandPrompt,
    required this.createAdiHttpClient,
    required this.hostServices,
    required this.createNativeLibraryLoader,
    required this.createHttpClient,
  });

  final http.Client Function() createHttpClient;
  final Log log;
  final CommandPrompt commandPrompt;
  final http.Client Function() createAdiHttpClient;
  final AppleHostServices hostServices;
  final NativeLibraryLoader Function() createNativeLibraryLoader;
  @override
  String get name => 'auth';

  @override
  String get description =>
      'Save App Store Connect API key credentials or sign in with Apple ID '
      'for the native (no-Swift) signing pipeline.';

  @override
  String get invocation =>
      'xcross auth [arguments]\n'
      '       xcross auth clean';

  @override
  String get usageFooter =>
      '\n"xcross auth clean" signs out: it deletes the saved App Store Connect '
      'key, the Apple ID session and its machine attestation state, and every '
      'certificate, private key, and provisioning profile xcross minted.';

  @override
  Future<void> run() {
    final rest = argResults!.rest;
    if (rest.isNotEmpty) {
      if (rest case ['clean']) return _clean();
      if (rest case ['clear']) {
        throw XcrossError(
          '"xcross auth clear" was renamed to "xcross auth clean".',
        );
      }
      throw XcrossError(
        'Unexpected argument "${rest.first}".\nUsage: $invocation',
      );
    }

    final usesAscKey =
        options.issuerIdWasParsed ||
        options.keyIdWasParsed ||
        options.privateKeyWasParsed;
    return usesAscKey ? _saveAscCredentials() : _appleIdLogin();
  }

  // ------------------------------------------------------------------ clean

  /// Per-user files and directories holding Apple authentication or signing
  /// material, under [configDirectory] (defaults to the xcross config dir).
  ///
  /// Deliberately an explicit list rather than the whole config directory:
  /// unrelated state (the update-check cache) and the architecture-specific
  /// ADI libraries live there too, and neither identifies an account.
  @visibleForTesting
  List<FileSystemEntity> authArtifacts(String configDirectory) {
    final files = hostServices.host.fileSystem;
    final paths = hostServices.host.paths.context;
    return [
      files.file(paths.join(configDirectory, 'appstoreconnect.json')),
      files.file(paths.join(configDirectory, 'grandslam-session.json')),
      files.file(paths.join(configDirectory, 'anisette-state.json')),
      files.file(paths.join(configDirectory, 'local.key')),
      files.directory(paths.join(configDirectory, 'adi')),
      files.directory(paths.join(configDirectory, 'signing')),
    ];
  }

  Future<void> _clean() async {
    final given = _authOptionNames.where(argResults!.wasParsed);
    if (given.isNotEmpty) {
      throw XcrossError(
        'xcross auth clean takes no options (got --${given.first}).',
      );
    }

    final configDirectory = hostServices.configDirectory;
    final removed = await deleteAuthArtifacts(configDirectory);
    for (final name in removed) {
      log.logInfo('Removed', name);
    }

    if (removed.isEmpty) {
      log.logDone('Nothing to clean in $configDirectory');
      return;
    }
    log.logDone(
      'Signed out. Run xcross auth to sign in again.',
      configDirectory,
    );
  }

  /// Deletes every [authArtifacts] entry that exists under [configDirectory],
  /// returning the names removed, relative to it.
  @visibleForTesting
  Future<List<String>> deleteAuthArtifacts(String configDirectory) async {
    final removed = <String>[];
    for (final (index, artifact) in authArtifacts(configDirectory).indexed) {
      if (!artifact.existsSync()) continue;
      // Directories hold minted certificates and their private keys, so the
      // delete has to be recursive to leave nothing behind.
      await artifact.delete(recursive: true);
      removed.add(
        const [
          'appstoreconnect.json',
          'grandslam-session.json',
          'anisette-state.json',
          'local.key',
          'adi',
          'signing',
        ][index],
      );
    }
    return removed;
  }

  // ---------------------------------------------------------------- ASC key

  Future<void> _saveAscCredentials() async {
    if (options.appleIdWasParsed) {
      throw XcrossError(
        'Use either App Store Connect API key flags or --apple-id, not both.',
      );
    }
    final issuerId = options.issuerId;
    final keyId = options.keyId;
    final privateKeyPath = options.privateKey;
    if (![issuerId, keyId, privateKeyPath].every(_present)) {
      throw XcrossError(
        'Provide non-empty values for all of --issuer-id, --key-id, and '
        '--private-key, or none to use Apple ID login.',
      );
    }
    if (options.adiLibraryDirWasParsed) {
      throw XcrossError('--adi-library-dir only applies to Apple ID login.');
    }

    final logicalKeyPath = hostServices.host.paths.context.absolute(
      privateKeyPath!,
    );
    final keyFile = hostServices.host.fileSystem.file(logicalKeyPath);
    if (!keyFile.existsSync()) {
      throw XcrossError('No file found at "$privateKeyPath".');
    }

    final configPath = AscCredentials.defaultConfigPath(
      hostServices: hostServices,
    );
    await AscCredentials(
      issuerId: issuerId!,
      keyId: keyId!,
      privateKeyPath: logicalKeyPath,
      hostServices: hostServices,
    ).save(path: configPath);
    // Authentication mode is explicit: a newly saved ASC key should not be
    // silently shadowed by an older still-unexpired Apple ID session.
    await GrandSlamSessionStore(hostServices: hostServices).clear();

    log.logDone('App Store Connect credentials saved to $configPath');
  }

  // --------------------------------------------------------------- Apple ID

  Future<void> _appleIdLogin() async {
    final appleId = options.appleId?.trim();
    if (options.appleIdWasParsed && !_present(appleId)) {
      throw XcrossError('--apple-id requires a non-empty email address.');
    }
    requireAppleIdHost(hostServices.abi);

    // Credentials before any await: keeps interactive stdin simple on Windows.
    final username = _present(appleId)
        ? appleId!
        : _readRequiredLine('Apple ID: ');
    final givenPassword = options.password;
    final password = _present(givenPassword)
        ? givenPassword
        : _readHiddenLine('Password: ', valueName: 'password');
    if (password == null || password.isEmpty) {
      throw XcrossError('No password entered.');
    }

    final adiLibraryDirectory = await _resolveAdiLibraryDirectory();
    final anisette = AnisetteDataProvider(
      adiLibraryDirectory,
      httpClient: createHttpClient(),
      hostServices: hostServices,
      loader: createNativeLibraryLoader(),
    );
    GrandSlamClient? loginClient;
    GrandSlamAppTokenExchange? tokenExchange;
    try {
      final endpoints = await log.logStep(
        'Resolving GrandSlam endpoints',
        anisette.resolveGrandSlamEndpoints,
      );
      loginClient = GrandSlamClient(
        httpClient: createHttpClient(),
        endpoints: endpoints,
        fetchAnisetteHeaders: anisette.fetchAnisetteHeaders,
      );
      final loginData = await log.logStep(
        'Signing in with Apple ID',
        () => loginClient!.login(
          username: username,
          password: password,
          fetchTwoFactorCode: _promptTwoFactorCode,
        ),
      );
      tokenExchange = GrandSlamAppTokenExchange(
        httpClient: createHttpClient(),
        endpoints: endpoints,
        fetchAnisetteHeaders: anisette.fetchAnisetteHeaders,
      );
      final token = await log.logStep(
        'Fetching Developer Services session',
        () => tokenExchange!.exchange(loginData),
      );
      final team = await _selectActiveTeam(token, anisette);

      final store = GrandSlamSessionStore(hostServices: hostServices);
      await store.save(
        GrandSlamSession(
          username: username,
          token: token,
          teamId: team.id,
          adiLibraryDirectory: adiLibraryDirectory,
        ),
      );
      log.logDone('Signed in as $username. Session saved to ${store.path}');
    } on XcrossError {
      rethrow;
    } on Object catch (e, st) {
      log.logError('Apple ID login failed: $e');
      log.logTrace('$st');
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
    final httpClient = createHttpClient();
    final List<DeveloperServicesTeam> teams;
    try {
      teams = await log.logStep(
        'Fetching Developer Services teams',
        () => DeveloperServicesTeamDiscoveryClient(
          fetchAnisetteHeaders: anisette.fetchAnisetteHeaders,
          httpClient: httpClient,
        ).listTeams(localeName: hostServices.localeName, token: token),
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
    commandPrompt.write('Multiple teams available. Choose one:\n');
    for (var i = 0; i < teams.length; i++) {
      commandPrompt.write('  [${i + 1}] ${teams[i].name} (${teams[i].id})\n');
    }
    while (true) {
      final raw = commandPrompt
          .readLine('Choice (1-${teams.length}): ')
          ?.trim();
      if (raw == null) {
        throw XcrossError('No team selection made (stdin closed).');
      }
      final choice = int.tryParse(raw);
      if (choice != null && choice >= 1 && choice <= teams.length) {
        return teams[choice - 1];
      }
      commandPrompt.write(
        'Invalid choice "$raw". Enter a number 1-${teams.length}.\n',
      );
    }
  }

  Future<String?> _promptTwoFactorCode(GrandSlamTwoFactorMode mode) async {
    log.stopStep();
    return _readRequiredLine(switch (mode) {
      GrandSlamTwoFactorMode.sms =>
        'Enter the verification code sent via SMS: ',
      GrandSlamTwoFactorMode.trustedDevice =>
        'Enter the verification code sent to your trusted device: ',
      GrandSlamTwoFactorMode.unspecified => 'Enter the verification code: ',
    });
  }

  // ------------------------------------------------------------- ADI libs

  @visibleForTesting
  static void requireAppleIdHost(Abi abi) {
    if (!AdiLibraryFetcher.supportsAbi(abi)) {
      throw XcrossError(
        'Built-in Apple ID/password login supports Linux and macOS x64/ARM64 '
        'and Windows x64/ARM64 (got $abi). '
        'On this platform use App Store Connect API key flags.',
      );
    }
  }

  Future<String> _resolveAdiLibraryDirectory() {
    final host = hostServices.host;
    final environment = host.environment.values;
    final home = environment['HOME'] ?? environment['USERPROFILE'];
    if (home == null) {
      throw StateError('Cannot determine a home directory (HOME is not set).');
    }
    return resolveAdiLibraryDirectory(
      configuredDirectory: options.adiLibraryDir,
      cacheDirectory: host.paths.context.join(home, '.cache', 'provision_dart'),
    );
  }

  @visibleForTesting
  Future<String> resolveAdiLibraryDirectory({
    required String cacheDirectory,
    String? configuredDirectory,
  }) async {
    final hostAbi = hostServices.abi;
    requireAppleIdHost(hostAbi);
    final logicalDirectory = hostServices.host.paths.context.absolute(
      configuredDirectory ?? cacheDirectory,
    );
    try {
      final existing = AdiLibraryResolver(
        hostServices: hostServices,
      ).resolve(logicalDirectory, abi: hostAbi);
      if (existing != null) return logicalDirectory;
    } on FormatException catch (error) {
      if (configuredDirectory != null) {
        throw XcrossError(
          'Invalid ADI libraries at "$logicalDirectory": ${error.message}',
        );
      }
    }
    if (configuredDirectory != null) {
      _throwMissingAdiLibs(logicalDirectory);
    }

    final fetcher = AdiLibraryFetcher(
      cacheDir: logicalDirectory,
      hostServices: hostServices,
      abi: hostAbi,
      createClient: createAdiHttpClient,
    );
    await log.logStep('Fetching Apple ADI libraries', fetcher.ensureLibraries);
    final resolved = AdiLibraryResolver(
      hostServices: hostServices,
    ).resolve(logicalDirectory, abi: hostAbi);
    if (resolved == null) _throwMissingAdiLibs(fetcher.libraryDirectory.path);
    return logicalDirectory;
  }

  static Never _throwMissingAdiLibs(String dir) {
    throw XcrossError(
      'Apple ID login needs ADI libraries at "$dir" '
      '(libCoreADI.so and/or libstoreservicescore.so missing). Place both '
      'there, or pass --adi-library-dir.',
    );
  }

  String _readRequiredLine(String label) {
    final value = commandPrompt.readLine(label)?.trim();
    if (!_present(value)) throw XcrossError('No value entered for $label');
    return value!;
  }

  String? _readHiddenLine(String label, {required String valueName}) =>
      commandPrompt.readSecret(label, valueName: valueName);

  static bool _present(String? value) => value != null && value.isNotEmpty;
}
