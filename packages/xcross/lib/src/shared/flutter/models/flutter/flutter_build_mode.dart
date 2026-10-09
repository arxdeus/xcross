import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';

/// Flutter build mode, with the per-mode inputs flutter_tools uses for iOS.
@internal
enum FlutterBuildMode {
  debug(engineArtifact: 'ios', patchedSdk: 'flutter_patched_sdk'),
  profile(engineArtifact: 'ios-profile', patchedSdk: 'flutter_patched_sdk'),
  release(
    engineArtifact: 'ios-release',
    patchedSdk: 'flutter_patched_sdk_product',
  );

  const FlutterBuildMode({
    required this.engineArtifact,
    required this.patchedSdk,
  });

  /// Flutter engine artifact directory holding this mode's device engine.
  final String engineArtifact;

  /// Platform kernel directory frontend_server compiles against.
  final String patchedSdk;

  /// Ahead-of-time compiled (profile and release).
  bool get isPrecompiled => this != debug;

  /// The AOT compiler mode, or `null` for JIT debug builds.
  IosGenSnapshotMode? get genSnapshotMode => switch (this) {
    debug => null,
    profile => IosGenSnapshotMode.profile,
    release => IosGenSnapshotMode.release,
  };

  /// The frontend_server options flutter_tools adds after the build's
  /// [dartDefines] (`buildModeOptions`). Debug and profile keep a
  /// `dart.vm.*` value the user set; release always forces its own.
  List<String> frontendServerOptions(List<String> dartDefines) {
    bool userSet(String key) =>
        dartDefines.any((define) => define.startsWith(key));
    const deleteToString = [
      '--delete-tostring-package-uri=dart:ui',
      '--delete-tostring-package-uri=package:flutter',
    ];
    return switch (this) {
      debug => [
        if (!userSet('dart.vm.profile')) '-Ddart.vm.profile=false',
        if (!userSet('dart.vm.product')) '-Ddart.vm.product=false',
        '--enable-asserts',
      ],
      profile => [
        if (!userSet('dart.vm.profile')) '-Ddart.vm.profile=true',
        if (!userSet('dart.vm.product')) '-Ddart.vm.product=false',
        ...deleteToString,
      ],
      release => [
        '-Ddart.vm.profile=false',
        '-Ddart.vm.product=true',
        ...deleteToString,
      ],
    };
  }
}
