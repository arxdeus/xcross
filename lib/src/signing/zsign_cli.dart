import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

/// Wrapper around the upstream `zsign` binary
/// (https://github.com/zhlynn/zsign) — a portable, MIT-licensed, native
/// code-signing tool. Intended as a Swift-toolchain-free stand-in for
/// `xtool install`'s signing step, primarily for Windows where `xtool`
/// itself cannot run.
///
/// NOTE: build/bundle plain `zhlynn/zsign`, never the `xtool-org/zsign`
/// fork — that fork's CLI entry point (`src/zsign.cpp`) is compiled out
/// (`#if 0`) because it ships as a C-ABI library for Swift consumption, not
/// a standalone executable. See `.github/workflows/build-zsign-windows.yml`
/// for the pinned CI build recipe.
///
/// Not wired into the build/run pipeline yet — this is the standalone
/// wrapper only; call sites land in a follow-up.
class ZsignCli {
  /// Env var to pin an exact `zsign` binary, checked before PATH/bundled
  /// lookup. Mainly for tests and future packaging.
  static const _envOverride = 'XCROSS_ZSIGN_PATH';

  static const _name = 'zsign';

  /// Platform-correct binary filename (`zsign` vs `zsign.exe`) — required
  /// because [ProcessRunner.which] does a literal filename match and does
  /// not append `.exe` itself.
  static String get _binaryName => Platform.isWindows ? '$_name.exe' : _name;

  /// Resolve the `zsign` binary to run, in priority order:
  ///
  ///  1. `XCROSS_ZSIGN_PATH` env var, if set.
  ///  2. `zsign`/`zsign.exe` on PATH — lets a user-installed system zsign
  ///     (e.g. via a package manager, as this project's README documents for
  ///     its other native tool dependencies) take priority over anything
  ///     bundled.
  ///  3. `zsign`/`zsign.exe` next to the running xcross executable — the
  ///     expected home for a binary shipped alongside a packaged xcross
  ///     release. (Actually placing the CI-built Windows binary there is a
  ///     separate packaging follow-up, not implemented here.)
  ///
  /// Throws [XcrossError] if none of the above resolve to an existing file.
  static Future<String> locate() async {
    final override = Platform.environment[_envOverride];
    if (override != null && override.isNotEmpty) {
      if (!File(override).existsSync()) {
        throw XcrossError(
          '$_envOverride is set to "$override" but no file exists there.',
        );
      }
      return override;
    }

    final onPath = await ProcessRunner.which(_binaryName);
    if (onPath != null) return onPath;

    final bundled = p.join(p.dirname(Platform.resolvedExecutable), _binaryName);
    if (File(bundled).existsSync()) return bundled;

    throw XcrossError(
      'Could not find "$_binaryName". Install zsign '
      '(https://github.com/zhlynn/zsign) and put it on PATH, or set '
      '$_envOverride to its full path.',
    );
  }

  /// Sign (or re-sign) `.app`/`.ipa` at [appOrIpaPath] with zsign:
  ///
  /// ```console
  /// zsign -k <privateKeyPemPath> -c <certificatePemPath>
  ///       -m <provisioningProfilePath> -o <outputPath ?? appOrIpaPath>
  ///       -z <zipLevel> <appOrIpaPath>
  /// ```
  ///
  /// [privateKeyPemPath] and [certificatePemPath] are separate PEM files
  /// (zsign accepts either PEM/DER or a `.p12`; xcross only needs the PEM
  /// pair, since a locally-generated RSA key and an Apple-issued cert are
  /// already separate files). Runs under a spinner whose grey tail shows
  /// zsign's own output, matching `XtoolCli.install`'s UX.
  ///
  /// Throws [XcrossError] (with zsign's stderr attached) on a non-zero exit.
  Future<void> sign({
    required String appOrIpaPath,
    required String privateKeyPemPath,
    required String certificatePemPath,
    required String provisioningProfilePath,
    String? outputPath,
    int zipLevel = 9,
  }) async {
    final executable = await ZsignCli.locate();
    final args = <String>[
      '-k',
      privateKeyPemPath,
      '-c',
      certificatePemPath,
      '-m',
      provisioningProfilePath,
      '-o',
      outputPath ?? appOrIpaPath,
      '-z',
      '$zipLevel',
      appOrIpaPath,
    ];

    final step = Log.beginStep('Signing with zsign');
    try {
      await ProcessRunner.runChecked(
        executable,
        args,
        label: 'zsign',
        tail: step,
      );
      step.done();
    } on Object {
      step.fail();
      rethrow;
    }
  }
}
