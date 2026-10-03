import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:cli_kit/src/composition/native_host.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/update/semver.dart';

const _encodedVersion = String.fromEnvironment(
  'XCROSS_VERSION',
  defaultValue: 'unreleased',
);
const _released = bool.fromEnvironment('XCROSS_RELEASED');

typedef BuildCliRun =
    Future<int> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
    });

Future<void> main() async {
  final snapshot = detectPlatformHostSnapshot();
  final log = Log(
    output: StreamLogOutput(
      stdout: stdout,
      stderr: stderr,
      supportsAnsi: stdout.hasTerminal && stdout.supportsAnsiEscapes,
      terminalColumns: () => stdout.hasTerminal ? stdout.terminalColumns : 80,
    ),
  );
  exitCode = await buildXcross(
    runner: ProcessRunner(
      snapshot.host,
      log: log,
      stdinStream: stdin,
      stdoutSink: stdout,
      stderrSink: stderr,
    ),
    output: stdout,
    errors: stderr,
    dartExecutable: snapshot.resolvedExecutable,
    packageRoot: Directory.current,
    encodedVersion: _encodedVersion,
    released: _released,
  );
}

Future<int> buildXcross({
  required ProcessRunner runner,
  required IOSink output,
  required IOSink errors,
  required String dartExecutable,
  required Directory packageRoot,
  required String encodedVersion,
  required bool released,
  BuildCliRun? runBuild,
}) async {
  final version = _normalizeVersion(Uri.decodeComponent(encodedVersion));
  _validateIdentity(packageRoot, version, released: released);
  final generated = File(
    p.join(packageRoot.path, 'lib', 'src', 'version.g.dart'),
  );
  final original = await generated.readAsBytes();
  try {
    await generated.writeAsString(_identitySource(version, released));
    final run =
        runBuild ??
        ((executable, arguments, {required workingDirectory}) => _runBuild(
          runner,
          executable,
          arguments,
          workingDirectory: workingDirectory,
          output: output,
          errors: errors,
        ));
    final xcrossBuild = p.join(
      packageRoot.path,
      'build',
      'cli',
      '${runner.host.name}_${runner.host.architecture}',
    );
    final xcrossResult = await _buildCliExecutable(
      run,
      packageRoot,
      dartExecutable: dartExecutable,
      target: 'bin/xcross.dart',
      output: xcrossBuild,
    );
    if (xcrossResult != 0) return xcrossResult;

    final xcrunBuild = p.join(packageRoot.path, 'build', 'xcrun');
    final xcrunResult = await _buildCliExecutable(
      run,
      packageRoot,
      dartExecutable: dartExecutable,
      target: 'bin/xcrun.dart',
      output: xcrunBuild,
    );
    if (xcrunResult != 0) return xcrunResult;

    final executable = runner.host.paths.executableName('xcrun');
    final source = p.join(xcrunBuild, 'bundle', 'bin', executable);
    final destination = p.join(
      p.join(xcrossBuild, 'bundle', 'bin'),
      executable,
    );
    await File(source).copy(destination);
    return 0;
  } finally {
    await generated.writeAsBytes(original, flush: true);
  }
}

Future<int> _buildCliExecutable(
  BuildCliRun run,
  Directory packageRoot, {
  required String dartExecutable,
  required String target,
  String? output,
}) => run(dartExecutable, [
  'build',
  'cli',
  '-t',
  target,
  if (output != null) ...['-o', output],
], workingDirectory: packageRoot.path);

void _validateIdentity(
  Directory packageRoot,
  String version, {
  required bool released,
}) {
  if (!released) {
    return;
  }
  final parsed = XcrossSemver.tryParse(version);
  if (parsed == null || parsed.isPreRelease) {
    throw ArgumentError.value(
      version,
      'encodedVersion',
      'released builds require a stable semver identity',
    );
  }
  final declared = _pubspecVersion(packageRoot);
  if (_core(declared) != _core(version)) {
    throw ArgumentError.value(
      version,
      'encodedVersion',
      'release identity $version does not match pubspec version $declared',
    );
  }
}

String _pubspecVersion(Directory packageRoot) {
  final pubspec = File(p.join(packageRoot.path, 'pubspec.yaml'));
  final declared = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync())?[1];
  if (declared == null) {
    throw StateError('no version: entry in ${pubspec.path}');
  }
  return declared;
}

String _normalizeVersion(String version) =>
    version.startsWith('v') ? version.substring(1) : version;

String _core(String version) => version.split(RegExp('[-+]')).first;

String _identitySource(String version, bool released) =>
    "part of 'version.dart';\n\n"
    'const String _xcrossBuildVersion = ${jsonEncode(version)};\n'
    'const bool _xcrossBuildReleased = $released;\n';

Future<int> _runBuild(
  ProcessRunner runner,
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required IOSink output,
  required IOSink errors,
}) async {
  final process = await runner.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  final stdoutDone = output.addStream(process.stdout);
  final stderrDone = errors.addStream(process.stderr);
  final result = await process.exitCode;
  await Future.wait([stdoutDone, stderrDone]);
  return result;
}
