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

  /// `-Ddart.vm.*` defines frontend_server receives for this mode.
  List<String> get vmDefines => [
    '-Ddart.vm.profile=${this == profile}',
    '-Ddart.vm.product=${this == release}',
  ];
}
