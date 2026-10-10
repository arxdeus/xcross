import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/composition/native_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/update/semver.dart';

// Release builds inject these with -D; see release.yml.
// ignore: do_not_use_environment
const _encodedVersion = String.fromEnvironment(
  'XCROSS_VERSION',
  defaultValue: 'unreleased',
);
// ignore: do_not_use_environment
const _released = bool.fromEnvironment('XCROSS_RELEASED');

/// Builds `OpenAppleMacrosServer` from this checkout's
/// `third_party/OpenAppleMacros` submodule and ships it in the bundle's
/// `lib/`. Off by default so source builds need no Swift toolchain; release.yml
/// turns it on.
// ignore: do_not_use_environment
const _bundleMacros = bool.fromEnvironment('XCROSS_BUNDLE_MACROS');

@internal
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
    // The environment flips this per build; it only looks constant here.
    // ignore: avoid_redundant_argument_values
    bundleMacros: _bundleMacros,
  );
}

@internal
Future<int> buildXcross({
  required ProcessRunner runner,
  required IOSink output,
  required IOSink errors,
  required String dartExecutable,
  required Directory packageRoot,
  required String encodedVersion,
  required bool released,
  bool bundleMacros = false,
  BuildCliRun? runBuild,
}) async {
  final version = _normalizeVersion(Uri.decodeComponent(encodedVersion));
  _validateIdentity(packageRoot, version, released: released);
  final generated = File(
    p.join(
      packageRoot.path,
      'lib',
      'src',
      'shared',
      'runtime',
      'version.g.dart',
    ),
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
    if (bundleMacros) {
      return await _bundleOpenAppleMacros(
        runner,
        run,
        packageRoot: packageRoot,
        libDirectory: p.join(xcrossBuild, 'bundle', 'lib'),
      );
    }
    return 0;
  } finally {
    await generated.writeAsBytes(original, flush: true);
  }
}

/// DLL names imported by the PE image [bytes], including delay-loaded ones.
///
/// Windows has no static Swift standard library, so the release ships the
/// Swift runtime DLLs the server actually imports. Reading the import table
/// keeps that set exact across Swift releases instead of guessing names.
@internal
List<String> peImportedLibraries(List<int> bytes) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  int u16(int offset) => data.getUint16(offset, Endian.little);
  int u32(int offset) => data.getUint32(offset, Endian.little);
  final pe = u32(0x3C);
  if (u32(pe) != 0x00004550) throw const FormatException('not a PE image');
  final sections = u16(pe + 6);
  final optional = pe + 24;
  final optionalSize = u16(pe + 20);
  final dataDirectories = optional + (u16(optional) == 0x20B ? 112 : 96);
  final sectionTable = optional + optionalSize;
  int fileOffset(int rva) {
    for (var index = 0; index < sections; index++) {
      final section = sectionTable + index * 40;
      final virtualSize = u32(section + 8);
      final virtualAddress = u32(section + 12);
      final rawSize = u32(section + 16);
      final size = virtualSize > rawSize ? virtualSize : rawSize;
      if (rva >= virtualAddress && rva < virtualAddress + size) {
        return rva - virtualAddress + u32(section + 20);
      }
    }
    throw FormatException('RVA 0x${rva.toRadixString(16)} is not mapped');
  }

  String name(int rva) {
    final start = fileOffset(rva);
    var end = start;
    while (bytes[end] != 0) {
      end++;
    }
    return String.fromCharCodes(bytes.sublist(start, end));
  }

  final names = <String>{};
  // Data directory 1 is the import table (20-byte descriptors, name at +12);
  // 13 is the delay-load table (32-byte descriptors, name at +4).
  for (final (directory, stride, nameOffset) in [(1, 20, 12), (13, 32, 4)]) {
    final rva = u32(dataDirectories + directory * 8);
    if (rva == 0) continue;
    for (var entry = fileOffset(rva); ; entry += stride) {
      final nameRva = u32(entry + nameOffset);
      if (nameRva == 0) break;
      names.add(name(nameRva));
    }
  }
  return names.toList();
}

Future<int> _bundleOpenAppleMacros(
  ProcessRunner runner,
  BuildCliRun run, {
  required Directory packageRoot,
  required String libDirectory,
}) async {
  final repository = packageRoot.parent.parent;
  final source = p.join(repository.path, 'third_party', 'OpenAppleMacros');
  if (!File(p.join(source, 'Package.swift')).existsSync()) {
    throw StateError(
      'third_party/OpenAppleMacros is missing; run '
      '`git submodule update --init third_party/OpenAppleMacros`',
    );
  }
  final swift = await runner.locateTool('swift');
  final scratch = p.join(packageRoot.path, 'build', 'open-apple-macros');
  final windows = runner.host.name == 'windows';
  final linux = runner.host.name == 'linux';
  final arguments = [
    'build',
    '--package-path',
    source,
    '--scratch-path',
    scratch,
    '--configuration',
    'release',
    '--product',
    'OpenAppleMacrosServer',
    // Linux builds against the official static Linux SDK (musl), as upstream
    // OpenAppleMacros does, so the server runs on any distribution without a
    // Swift installation. `--static-swift-stdlib` on glibc cannot link a
    // static Foundation.
    if (linux) ...['--swift-sdk', _staticLinuxSdk(runner.host.architecture)],
  ];
  final built = await run(swift, arguments, workingDirectory: source);
  if (built != 0) return built;
  final binPath = await runner.run(swift, [
    ...arguments,
    '--show-bin-path',
  ], workingDirectory: source);
  final bin = binPath.stdout.trim().split('\n').last.trim();
  final name = runner.host.paths.executableName('OpenAppleMacrosServer');
  final server = File(p.join(bin, name));
  if (binPath.exitCode != 0 || !server.existsSync()) {
    throw StateError('swift build did not produce ${server.path}');
  }
  await Directory(libDirectory).create(recursive: true);
  final destination = p.join(libDirectory, name);
  await server.copy(destination);
  runner.makeExecutable(destination);
  if (windows) {
    await _copyWindowsSwiftRuntime(runner, swift, libDirectory);
  }
  return 0;
}

/// Static Linux SDK id for the host architecture.
String _staticLinuxSdk(String architecture) => switch (architecture) {
  'x64' => 'x86_64-swift-linux-musl',
  'arm64' => 'aarch64-swift-linux-musl',
  _ => throw UnsupportedError('No static Linux SDK for $architecture'),
};

/// Copies every Swift runtime DLL the bundled server needs, transitively,
/// from the toolchain's runtime directory into [libDirectory].
Future<void> _copyWindowsSwiftRuntime(
  ProcessRunner runner,
  String swift,
  String libDirectory,
) async {
  final info = await runner.run(swift, ['-print-target-info']);
  final decoded = jsonDecode(info.stdout) as Map<String, Object?>;
  final paths = decoded['paths']! as Map<String, Object?>;
  final runtimeLibraryPaths = (paths['runtimeLibraryPaths'] as List<Object?>?)
      ?.cast<String>();
  final pathDirectories =
      (runner.host.environment.lookup(runner.effectiveEnvironment, 'PATH') ??
              '')
          .split(';');
  final candidates = [...?runtimeLibraryPaths, ...pathDirectories];
  final runtime = candidates.firstWhere(
    (directory) => File(p.join(directory, 'swiftCore.dll')).existsSync(),
    orElse: () => throw StateError(
      'Could not find the Swift runtime (swiftCore.dll) for $swift',
    ),
  );
  final available = {
    for (final file in Directory(runtime).listSync().whereType<File>())
      if (file.path.toLowerCase().endsWith('.dll'))
        p.basename(file.path).toLowerCase(): file,
  };
  final pending = [
    File(p.join(libDirectory, runner.host.paths.executableName(_server))),
  ];
  final copied = <String>{};
  while (pending.isNotEmpty) {
    final image = pending.removeLast();
    for (final library in peImportedLibraries(image.readAsBytesSync())) {
      final key = library.toLowerCase();
      final source = available[key];
      // System and MSVC runtime DLLs are not in the Swift runtime directory.
      if (source == null || !copied.add(key)) continue;
      final destination = File(p.join(libDirectory, p.basename(source.path)));
      await source.copy(destination.path);
      pending.add(destination);
    }
  }
  if (!copied.contains('swiftcore.dll')) {
    throw StateError('$_server imports no swiftCore.dll from $runtime');
  }
  runner.log.logInfo(
    'Bundled Swift runtime for $_server: ${(copied.toList()..sort()).join(', ')}',
  );
}

const _server = 'OpenAppleMacrosServer';

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
