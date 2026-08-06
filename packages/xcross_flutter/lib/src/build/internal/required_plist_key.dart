import 'package:meta/meta.dart';

/// A plist key/value pair Xcode would inject at build time.
@immutable
final class RequiredPlistKey {
  const RequiredPlistKey({required this.key, required this.value});

  final String key;
  final String value;
}
