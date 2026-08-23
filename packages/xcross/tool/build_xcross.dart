import 'dart:convert';
import 'dart:io';

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
  exitCode = await buildXcross(
    packageRoot: Directory.current,
    encodedVersion: _encodedVersion,
    released: _released,
  );
}

Future<int> buildXcross({
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
    return await (runBuild ?? _runBuild)(Platform.resolvedExecutable, const [
      'build',
      'cli',
      '-t',
      'bin/xcross.dart',
    ], workingDirectory: packageRoot.path);
  } finally {
    await generated.writeAsBytes(original, flush: true);
  }
}

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

String _core(String version) => version.split(RegExp(r'[-+]')).first;

String _identitySource(String version, bool released) =>
    "part of 'version.dart';\n\n"
    'const String _xcrossBuildVersion = ${jsonEncode(version)};\n'
    'const bool _xcrossBuildReleased = $released;\n';

Future<int> _runBuild(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  final stdoutDone = stdout.addStream(process.stdout);
  final stderrDone = stderr.addStream(process.stderr);
  final result = await process.exitCode;
  await Future.wait([stdoutDone, stderrDone]);
  return result;
}
