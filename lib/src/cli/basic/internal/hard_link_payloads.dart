import 'dart:typed_data';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';

/// `(dev, ino)` identity of a cpio hard-link group.
@immutable
final class CpioHardLinkKey {
  const CpioHardLinkKey({required this.dev, required this.ino});

  final int dev;
  final int ino;

  @override
  bool operator ==(Object other) =>
      other is CpioHardLinkKey && other.dev == dev && other.ino == ino;

  @override
  int get hashCode => Object.hash(dev, ino);
}

/// A hard-link group's cached payload and remaining unseen entries.
@immutable
final class HardLinkPayload {
  const HardLinkPayload({required this.data, required this.remaining});

  final Uint8List data;
  final int remaining;
}

/// cpio writes a hard link's bytes once and leaves later entries for the same
/// `(dev, ino)` empty, so the first payload seen has to be replayed for the
/// rest of the group — even when that first entry is outside the SDK subset.
final class HardLinkPayloads {
  // ponytail: archive-order cache is memory-bound; disk-spool only if a future
  // Xcode archive makes pending groups large.
  final _pending = <CpioHardLinkKey, HardLinkPayload>{};

  Uint8List payloadFor(CpioEntry entry, {required bool isRegular}) {
    if (!isRegular || entry.nlink <= 1) return entry.data;

    final key = CpioHardLinkKey(dev: entry.dev, ino: entry.ino);
    final group = _pending[key];
    if (group == null) {
      _pending[key] = HardLinkPayload(
        data: entry.data,
        remaining: entry.nlink - 1,
      );
      return entry.data;
    }
    if (group.remaining == 1) {
      _pending.remove(key);
    } else {
      _pending[key] = HardLinkPayload(
        data: group.data,
        remaining: group.remaining - 1,
      );
    }
    return group.data;
  }
}
