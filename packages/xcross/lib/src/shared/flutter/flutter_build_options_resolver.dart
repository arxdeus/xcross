import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/flutter/project/dart_defines_reader.dart';

@internal
final class FlutterBuildOptionsResolver {
  FlutterBuildOptionsResolver(this.defines);

  final DartDefinesReader defines;

  /// Build options from raw CLI arguments, merging `--dart-define-from-file`
  /// entries (lower precedence) with explicit `--dart-define` entries.
  Future<FlutterBuildOptions> resolve({
    required String target,
    required List<String> dartDefine,
    required List<String> dartDefineFromFile,
    required bool pub,
    String? buildName,
    String? buildNumber,
    String? flavor,
    FlutterBuildMode buildMode = FlutterBuildMode.debug,
    bool treeShakeIcons = true,
    String? splitDebugInfo,
    bool obfuscate = false,
  }) async => FlutterBuildOptions(
    target: target,
    dartDefines: await defines.mergeDartDefines(dartDefineFromFile, dartDefine),
    pub: pub,
    buildName: buildName,
    buildNumber: buildNumber,
    flavor: flavor,
    buildMode: buildMode,
    treeShakeIcons: treeShakeIcons,
    splitDebugInfo: splitDebugInfo,
    obfuscate: obfuscate,
  );
}
