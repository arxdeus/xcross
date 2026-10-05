import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/swift_environment_host.dart';

@internal
enum WindowsSdkRootSource { environment, user, machine, toolchain }

@internal
final class WindowsSdkRootResolution {
  const WindowsSdkRootResolution({
    required this.inherited,
    required this.path,
    required this.source,
    required this.searched,
  });
  final String? inherited;
  final String? path;
  final WindowsSdkRootSource? source;
  final List<String> searched;
}

@internal
final class WindowsSwiftEnvironment implements SwiftEnvironmentHostInterface {
  WindowsSwiftEnvironment(this.runner);
  final ProcessRunner runner;
  Future<WindowsSdkRootResolution>? _resolution;

  static const _variable = 'SDKROOT';
  static const _userKey = r'HKCU\Environment';
  static const _machineKey =
      r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

  PlatformHostInterface get host => runner.host;
  p.Context get _paths => host.paths.context;

  Future<WindowsSdkRootResolution> resolve() => _resolution ??= _resolve();

  @override
  Future<Map<String, String>> swiftEnvironment() async {
    final resolution = await resolve();
    final path = resolution.path;
    if (path == null) throw XcrossError(missingMessage(resolution));
    if (resolution.source == WindowsSdkRootSource.environment) return const {};
    if (resolution.inherited case final inherited?) {
      runner.log.logWarn(
        '$_variable "$inherited" is not a Windows SDK for Swift; using '
        '"$path" from ${_describe(resolution)}.',
      );
    } else {
      runner.log.logTrace(
        '$_variable is not set; using "$path" from ${_describe(resolution)}.',
      );
    }
    return {_variable: path};
  }

  @override
  Future<List<DoctorCheck>> doctorChecks() async {
    final resolution = await resolve();
    final path = resolution.path;
    final inherited = resolution.inherited;
    if (path == null) {
      return [DoctorCheck.failure(_variable, missingMessage(resolution))];
    }
    if (resolution.source == WindowsSdkRootSource.environment) {
      return [DoctorCheck.success(_variable, 'Set', path: path)];
    }
    if (inherited != null) {
      return [
        DoctorCheck.warning(
          _variable,
          'Set to "$inherited", which is not a Windows SDK for Swift. '
          'xcross passes the SDK from ${_describe(resolution)} to Swift '
          'instead; fix $_variable so other Swift tools work too.',
          path: path,
        ),
      ];
    }
    return [
      DoctorCheck.success(
        _variable,
        'Not set in this environment; xcross passes the SDK from '
        '${_describe(resolution)} to Swift.',
        path: path,
      ),
    ];
  }

  String missingMessage(WindowsSdkRootResolution resolution) {
    final inherited = resolution.inherited;
    final problem = inherited == null
        ? '$_variable is not set and no Windows SDK for Swift was found'
        : '$_variable is set to "$inherited", which is not a Windows SDK for '
              'Swift, and no other one was found';
    const example =
        r'%LOCALAPPDATA%\Programs\Swift\Platforms\<version>'
        r'\Windows.platform\Developer\SDKs\Windows.sdk';
    return '$problem, so SwiftPM cannot compile Package.swift manifests for '
        'this host.\n'
        'Searched: ${resolution.searched.join('; ')}.\n'
        'Set $_variable to the Windows.sdk directory of your Swift install, '
        'e.g. $example, or reinstall Swift for Windows and open a new '
        'terminal.';
  }

  String _describe(WindowsSdkRootResolution resolution) =>
      switch (resolution.source) {
        WindowsSdkRootSource.user => 'the User environment in the registry',
        WindowsSdkRootSource.machine =>
          'the Machine environment in the registry',
        WindowsSdkRootSource.toolchain => 'the Swift toolchain installation',
        WindowsSdkRootSource.environment || null => 'this environment',
      };

  Future<WindowsSdkRootResolution> _resolve() async {
    final environment = runner.effectiveEnvironment;
    final value = host.environment.lookup(environment, _variable)?.trim();
    final inherited = value == null || value.isEmpty ? null : value;
    final searched = <String>[];
    WindowsSdkRootResolution found(String path, WindowsSdkRootSource source) =>
        WindowsSdkRootResolution(
          inherited: source == WindowsSdkRootSource.environment
              ? path
              : inherited,
          path: path,
          source: source,
          searched: searched,
        );
    if (inherited != null) {
      searched.add('$_variable in this environment');
      if (_valid(inherited)) {
        return found(inherited, WindowsSdkRootSource.environment);
      }
    }
    for (final (key, source) in [
      (_userKey, WindowsSdkRootSource.user),
      (_machineKey, WindowsSdkRootSource.machine),
    ]) {
      searched.add('$key\\$_variable');
      final registered = await _registryValue(key);
      if (registered != null && _valid(registered)) {
        return found(registered, source);
      }
    }
    final derived = await _toolchainSdk(searched);
    if (derived != null) return found(derived, WindowsSdkRootSource.toolchain);
    return WindowsSdkRootResolution(
      inherited: inherited,
      path: null,
      source: null,
      searched: searched,
    );
  }

  String _expand(String value) => value.replaceAllMapped(
    RegExp('%([^%]+)%'),
    (match) =>
        host.environment.lookup(runner.effectiveEnvironment, match[1]!) ??
        match[0]!,
  );

  bool _valid(String path) {
    final expanded = _expand(path);
    return host.fileSystem.directory(expanded).existsSync() &&
        host.fileSystem
            .directory(_paths.join(expanded, 'usr', 'lib', 'swift', 'windows'))
            .existsSync();
  }

  String get _reg {
    final root = host.environment.lookup(
      runner.effectiveEnvironment,
      'SystemRoot',
    );
    return root == null || root.isEmpty
        ? 'reg.exe'
        : _paths.join(root, 'System32', 'reg.exe');
  }

  Future<String?> _registryValue(String key) async {
    try {
      final result = await runner.run(_reg, ['query', key, '/v', _variable]);
      if (result.exitCode != 0) return null;
      final value = RegExp(
        r'^\s*SDKROOT\s+REG_(?:EXPAND_)?SZ\s+(.*?)\s*$',
        multiLine: true,
        caseSensitive: false,
      ).firstMatch(result.stdout)?[1];
      return value == null || value.isEmpty ? null : _expand(value);
    } on Object catch (error) {
      runner.log.logTrace('Could not read $key\\$_variable: $error');
      return null;
    }
  }

  Future<String?> _toolchainSdk(List<String> searched) async {
    final swift = await runner.which('swift');
    if (swift == null) {
      searched.add('the Swift toolchain (swift is not on PATH)');
      return null;
    }
    final toolchain = _paths.dirname(
      _paths.dirname(_paths.dirname(_paths.normalize(swift))),
    );
    final platforms = _paths.join(
      _paths.dirname(_paths.dirname(toolchain)),
      'Platforms',
    );
    searched.add(
      _paths.join(
        platforms,
        '*',
        'Windows.platform',
        'Developer',
        'SDKs',
        'Windows.sdk',
      ),
    );
    final directory = host.fileSystem.directory(platforms);
    if (!directory.existsSync()) return null;
    final versions = <String, String>{};
    for (final entry in directory.listSync(followLinks: false)) {
      final version = _paths.basename(entry.path);
      final sdk = _paths.join(
        platforms,
        version,
        'Windows.platform',
        'Developer',
        'SDKs',
        'Windows.sdk',
      );
      if (_valid(sdk)) versions[version] = sdk;
    }
    final toolchainVersion = _paths.basename(toolchain).split('+').first;
    return versions[toolchainVersion] ??
        (versions.length == 1 ? versions.values.single : null);
  }
}
