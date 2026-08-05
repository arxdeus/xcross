import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/util/errors.dart';

export 'package:xcross/src/cli/basic/sdk_install.dart';

/// `xcross sdk` — manage xcross's host-neutral Darwin Swift SDK.
class SdkCommand extends Command<void> {
  SdkCommand() {
    addSubcommand(SdkInstallCommand());
  }

  @override
  String get name => 'sdk';

  @override
  String get description => 'Manage the xcross Darwin Swift SDK.';
}

/// `xcross sdk install <Xcode.xip>` — build xcross's Darwin Swift SDK bundle.
class SdkInstallCommand extends Command<void> {
  @override
  String get name => 'install';

  @override
  String get description =>
      'Extract a host-neutral Darwin Swift SDK from an Xcode.xip.';

  @override
  String get invocation => 'xcross sdk install <path-to-Xcode.xip>';

  static const _progressInterval = 250;

  @override
  Future<void> run() async {
    final xipPath = argResults!.rest.firstOrNull;
    if (xipPath == null) throw XcrossError('Usage: $invocation');
    if (!File(xipPath).existsSync()) {
      throw XcrossError('No file found at "$xipPath".');
    }

    final destDir = DarwinSdk.nativeInstallDir();
    final previous = Directory(SdkInstall.ioPath(destDir));
    if (previous.existsSync()) await previous.delete(recursive: true);

    final written = await _extract(xipPath, destDir);
    if (written == 0) {
      throw XcrossError(
        '$xipPath: extraction produced no files from the required iOS SDK '
        'subset. Verify that this is a complete Xcode.xip.',
      );
    }

    await SdkInstall.replaceClangBuiltinHeaders(destDir);
    await SdkInstall.materializeSwiftCompatibilityResources(destDir);
    await SdkInstall.writeSwiftSdkBundleMetadata(destDir);
    Log.logDone('Installed Darwin Swift SDK ($written entries) at $destDir');
  }

  Future<int> _extract(String xipPath, String destDir) async {
    final step = Log.beginStep('Extracting Darwin Swift SDK from Xcode.xip');
    try {
      final written = await SdkInstall.writeSdkEntries(
        XcodeXipExtractor.extract(xipPath),
        destDir,
        onProgress: (count) {
          if (count % _progressInterval == 0) {
            step.log('$count entries extracted…\n');
          }
        },
      );
      step.done('Extracted $written entries');
      return written;
    } on Object {
      step.fail();
      rethrow;
    }
  }
}
