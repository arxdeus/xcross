import 'package:meta/meta.dart';

/// Which inputs the encryption key is derived from. Recorded in every
/// envelope so that opening never depends on re-detecting the environment.
@internal
enum LocalCipherBinding {
  /// Key file + machine id: the config directory is useless elsewhere.
  machine('machine'),

  /// Key file only: the config directory travels with its `local.key`.
  /// Used where no stable machine id exists, such as containers.
  keyOnly('key-only');

  const LocalCipherBinding(this.wireName);

  final String wireName;

  static LocalCipherBinding? byWireName(Object? name) {
    for (final binding in values) {
      if (binding.wireName == name) return binding;
    }
    return null;
  }
}
