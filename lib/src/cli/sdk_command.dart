import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'package:xcross/src/darwinsdk/xcode_xip_extractor.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/xtool/darwin_sdk.dart';

/// `xcross sdk` \u2014 manage the native (no-Xcode/Swift) Darwin/iOS SDK.
class SdkCommand extends Command<void> {
  SdkCommand() {
    addSubcommand(SdkInstallCommand());
  }

  @override
  String get name => 'sdk';

  @override
  String get description => 'Manage the native (no-Xcode/Swift) Darwin SDK.';
}

/// The path fragment marking the start of the iPhoneOS SDK sysroot inside a
/// decoded Xcode.xip cpio entry name. Matched as a substring rather than an
/// assumed exact prefix (e.g. `Xcode.app/Contents/Developer/...` vs. some
/// other root) because the real prefix ahead of it hasn't been confirmed
/// against an actual Xcode.xip \u2014 searching for this anchor and keeping
/// everything from it onward is robust to that prefix being wrong.
const sdkAnchor = 'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/';

/// Destination-relative path for cpio entry [name] \u2014 everything from
/// [sdkAnchor] onward \u2014 or null if [name] isn't under the iPhoneOS SDK
/// sysroot (and so should be skipped by `xcross sdk install`).
String? sdkRelativePath(String name) {
  final index = name.indexOf(sdkAnchor);
  return index < 0 ? null : name.substring(index);
}

/// `xcross sdk install <Xcode.xip>` \u2014 extract just the iPhoneOS SDK sysroot
/// out of an Xcode.xip using the pure-Dart extractor in `lib/src/darwinsdk/`
/// (XAR + pbzx + cpio, no `xar`/Swift/Xcode/xtool needed), and install it
/// under [DarwinSdk.nativeInstallDir] so [DarwinSdk.current] picks it up \u2014
/// this is what makes `xcross flutter build`/`run`'s toolchain resolution
/// work natively on Windows, without WSL or a Linux/macOS `xtool sdk
/// install` run.
///
/// **UNVALIDATED against a real Xcode.xip** \u2014 the extractor
/// (`xcode_xip_extractor.dart`) was written and tested only against
/// hand-built synthetic fixtures matching the documented wire formats; a
/// real Xcode.xip is a multi-gigabyte, Apple-account-gated download that was
/// unavailable in the environment this was written in. Confirm this
/// extracts a plausible SDK tree before relying on it for a real build.
class SdkInstallCommand extends Command<void> {
  @override
  String get name => 'install';

  @override
  String get description =>
      'Extract the iPhoneOS SDK from an Xcode.xip natively (no Xcode, '
      'Swift, or xtool required). UNVALIDATED against a real Xcode.xip.';

  @override
  String get invocation => 'xcross sdk install <path-to-Xcode.xip>';

  /// How often to update the progress line while extracting \u2014 a real
  /// iPhoneOS SDK sysroot has thousands of header files; one line per file
  /// would flood the console.
  static const _progressInterval = 250;

  @override
  Future<void> run() async {
    final xipPath = argResults!.rest.firstOrNull;
    if (xipPath == null) {
      throw XcrossError('Usage: $invocation');
    }
    if (!File(xipPath).existsSync()) {
      throw XcrossError('No file found at "$xipPath".');
    }

    final destDir = DarwinSdk.nativeInstallDir();
    final written = await _extract(xipPath, destDir);

    if (written == 0) {
      throw XcrossError(
        '$xipPath: extraction produced zero iPhoneOS SDK files.\n'
        "Either this isn't a real Xcode.xip, or the pure-Dart extractor's "
        'assumptions about the cpio entry-name layout are wrong for this '
        'file \u2014 it has not been validated against a real Xcode.xip (see '
        'lib/src/darwinsdk/xcode_xip_extractor.dart).',
      );
    }

    await File(p.join(destDir, 'darwin-sdk-version.txt')).writeAsString(
      'xcross native (Xcode.xip extractor), extracted '
      '${DateTime.now().toIso8601String()}\n',
    );

    Log.logDone('Extracted $written iPhoneOS SDK files to $destDir');
    Log.logWarn(
      'This extractor is UNVALIDATED against a real Xcode.xip \u2014 verify the '
      'SDK tree looks right before relying on it for a real build.',
    );
  }

  /// Streams [xipPath]'s decoded cpio content, writing every entry under the
  /// iPhoneOS SDK sysroot to [destDir]. Returns the number of files written.
  Future<int> _extract(String xipPath, String destDir) async {
    var written = 0;
    final step = Log.beginStep('Extracting iPhoneOS SDK from Xcode.xip');
    try {
      await for (final entry in extractXcodeXipContent(xipPath)) {
        final relative = sdkRelativePath(entry.name);
        if (relative == null) continue;

        final destPath = p.join(destDir, relative);
        await Directory(p.dirname(destPath)).create(recursive: true);
        await File(destPath).writeAsBytes(entry.data);
        // Owner/group/other execute bits \u2014 same mask as the rest of this
        // codebase's mode checks (see test/util/process_test.dart).
        if (entry.mode & 0x49 != 0) ProcessRunner.makeExecutable(destPath);

        written++;
        if (written % _progressInterval == 0) {
          step.log('$written files extracted\u2026\n');
        }
      }
      step.done('Extracted $written files');
    } on Object {
      step.fail();
      rethrow;
    }
    return written;
  }
}
