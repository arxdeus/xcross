import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';

/// Where a host gets the iOS AOT compiler (`gen_snapshot`) from.
///
/// Flutter ships that compiler for macOS only. Other hosts use the prebuilt
/// compilers published by xcross_gen_snapshot for their [prebuiltPlatform].
@internal
abstract interface class IosGenSnapshotHost {
  PlatformHostInterface get host;

  /// xcross_gen_snapshot asset platform for this host, such as `linux-x64`.
  String get prebuiltPlatform;

  /// The compiler Flutter ships beside the [mode] device engine in
  /// [engineDirectory], or `null` when Flutter publishes none for this host.
  String? flutterCompiler(String engineDirectory, IosGenSnapshotMode mode);
}
