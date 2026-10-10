import 'package:meta/meta.dart';

/// Flutter build mode an iOS AOT compiler (`gen_snapshot`) is built for.
///
/// Release and profile compilers differ (product mode, service isolate), so
/// each mode has its own compiler.
@internal
enum IosGenSnapshotMode {
  release('ios-release'),
  profile('ios-profile');

  const IosGenSnapshotMode(this.engineArtifact);

  /// Flutter engine artifact directory holding this mode's iOS engine.
  final String engineArtifact;
}
