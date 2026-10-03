import 'package:cli_kit/cli_kit_shared.dart';

final class XcrossIdeLauncher {
  XcrossIdeLauncher({
    required this.log,
    required this.host,
    required this.executable,
    this.configPath,
    this.flutterRoot,
    this.declarative = false,
  });

  final Log log;
  final PlatformHostInterface host;
  final String executable;
  final String? configPath;
  final String? flutterRoot;
  final bool declarative;

  Map<String, String> get generatedEnvironment => {
    if (configPath case final path?) 'XCROSS_CONFIG': path,
    if (flutterRoot case final root?) 'FLUTTER_ROOT': root,
  };

  bool get inheritParentEnvironment => !declarative;

  String resolve({required String subcommand, required String brokenFeature}) {
    if (host.paths.context.basenameWithoutExtension(executable) != 'xcross') {
      log.logWarn(
        'embedding $executable: run `xcross ide $subcommand` from the installed binary, not `dart run`, or $brokenFeature will not work',
      );
    }
    return executable;
  }
}
