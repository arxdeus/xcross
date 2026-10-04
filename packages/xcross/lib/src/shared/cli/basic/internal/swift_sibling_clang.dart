import 'package:meta/meta.dart';

/// The clang shipped beside a resolved `swift` executable.
@immutable
final class SwiftSiblingClang {
  const SwiftSiblingClang({required this.clang, required this.swift});

  final String clang;
  final String swift;

  @override
  bool operator ==(Object other) =>
      other is SwiftSiblingClang &&
      other.clang == clang &&
      other.swift == swift;

  @override
  int get hashCode => Object.hash(clang, swift);

  @override
  String toString() => 'SwiftSiblingClang(clang: $clang, swift: $swift)';
}
