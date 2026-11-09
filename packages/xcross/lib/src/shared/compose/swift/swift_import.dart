import 'package:meta/meta.dart';

/// One `import` declaration found in a Swift source of a KMP app host.
///
/// [module] is always the top-level module name: `import UIKit`,
/// `import UIKit.UIGestureRecognizerSubclass`, `@testable import UIKit` and
/// `import struct UIKit.CGFloat` all yield `UIKit`, because only the
/// top-level module decides whether the import resolves against the SDK.
@internal
@immutable
final class SwiftImport {
  const SwiftImport(
    this.module, {
    required this.path,
    required this.line,
    this.conditional = false,
  });

  final String module;

  /// Source file the import was found in.
  final String path;

  /// 1-based line of the `import` keyword in [path].
  final int line;

  /// True when the import sits inside an `#if` block (typically
  /// `#if canImport(X)`), so the build does not require [module] to exist.
  final bool conditional;

  @override
  bool operator ==(Object other) =>
      other is SwiftImport &&
      other.module == module &&
      other.path == path &&
      other.line == line &&
      other.conditional == conditional;

  @override
  int get hashCode => Object.hash(module, path, line, conditional);

  @override
  String toString() =>
      '$path:$line: import $module${conditional ? ' (conditional)' : ''}';
}
