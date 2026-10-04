import 'package:meta/meta.dart';
part 'version.g.dart';

@internal
abstract final class XcrossVersion {
  static const String current = _xcrossBuildVersion;
  static const bool isReleased = _xcrossBuildReleased;
  static bool get isDev => !isReleased;

  static String describe() =>
      isReleased ? 'xcross $current' : 'xcross $current (unreleased build)';
}
