import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// The directory, relative to the KMP project root, that holds the SwiftUI
/// host xcross discovers and compiles.
@internal
const swiftHostDirectory = 'iosApp';

/// Whether [path] (absolute, or relative to the project root) is a Swift
/// source of the SwiftUI host that discovery reads.
///
/// Discovery and `compose run --watch` must agree on this set: a `.swift`
/// file discovery ignores (Xcode previews, test targets, CocoaPods or
/// Carthage checkouts) cannot change the build, so watching it would only
/// trigger a Kotlin/Native rebuild that produces the same app.
@internal
bool isSwiftHostSource(String path, {required String projectRoot}) {
  if (p.extension(path) != '.swift') return false;
  final relative = p.isRelative(path)
      ? p.normalize(path)
      : p.relative(path, from: projectRoot);
  final segments = p.split(relative);
  if (segments.length < 2 || segments.first != swiftHostDirectory) {
    return false;
  }
  return !segments.any(isExcludedSwiftHostSegment);
}

/// Path segments whose Swift files are never part of the host xcross
/// compiles: Xcode preview assets, unit and UI test targets, and third-party
/// dependency checkouts that xcross does not link.
@internal
bool isExcludedSwiftHostSegment(String segment) =>
    segment == 'Preview Content' ||
    segment == 'Pods' ||
    segment == 'Carthage' ||
    segment.endsWith('Tests');
