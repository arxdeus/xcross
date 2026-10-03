import 'dart:convert';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/update/release_lookup.dart';
import 'package:xcross/src/update/semver.dart';
import 'package:xcross/src/version.dart';

/// Background "a newer xcross exists" notice.
///
/// The hint is printed from the cache, never from a live request, so no
/// command pays for the network. The refresh runs after the command finished
/// and its result is what the *next* invocation reports.
final class UpdateCheck {
  const UpdateCheck(
    this.host, {
    required this.log,
    required this.outputHasTerminal,
    required this.releaseLookup,
    this.released = XcrossVersion.isReleased,
  });
  final PlatformHostInterface host;
  final Log log;
  final bool outputHasTerminal;
  final ReleaseLookup releaseLookup;
  final bool released;

  /// How long a cached answer is trusted.
  static const interval = Duration(hours: 24);

  /// Ceiling on the post-command refresh, so a slow network cannot hold the
  /// process open after the real work is done.
  static const refreshTimeout = Duration(milliseconds: 1500);

  /// Set to any value to silence the check entirely.
  static const disableEnvVar = 'XCROSS_NO_UPDATE_CHECK';

  /// Whether the passive check may run at all.
  ///
  /// Off for unreleased builds (nothing to compare against), for machine
  /// consumers of stdout, for CI, and whenever the user opted out.
  bool isEnabled({required bool ownsStdout}) {
    if (ownsStdout || !released) return false;
    final env = host.environment.values;
    if (env.containsKey(disableEnvVar) || env.containsKey('CI')) return false;
    // Under `sudo xcross ...` the cache path still resolves through the
    // invoking user's HOME, so writing it as root would follow whatever that
    // user planted there.
    if (env.containsKey('SUDO_USER')) return false;
    return outputHasTerminal;
  }

  /// Prints a one-line hint when the cache knows of a newer release.
  void printHintFromCache() {
    final latest = _read()?.latest;
    if (latest == null) return;
    if (!isNewerThanCurrent(latest)) return;
    log.logStatus(log.dim("update available: $latest (run 'xcross update')"));
  }

  /// True when [tag] is a release newer than the running build.
  static bool isNewerThanCurrent(String tag) {
    final latest = XcrossSemver.tryParse(tag);
    final current = XcrossSemver.tryParse(XcrossVersion.current);
    if (latest == null || current == null) return false;
    return latest.isNewerThan(current);
  }

  /// Refreshes the cache when it is stale. Never throws and never blocks for
  /// longer than [refreshTimeout].
  Future<void> refreshIfStale() async {
    final cached = _read();
    if (cached != null && !cached.isStale) return;
    try {
      final tag = await releaseLookup
          .latestTag(
            environment: host.environment.values,
            timeout: refreshTimeout,
          )
          .timeout(refreshTimeout);
      _write(tag);
    } on Object {
      // An unreachable or rate-limited GitHub must never affect the exit code;
      // stamp the cache so the next run does not retry immediately either.
      _write(null);
    }
  }

  /// `%APPDATA%/xcross/update_check.json` on Windows,
  /// `$XDG_CONFIG_HOME/xcross/update_check.json` (falling back to
  /// `~/.config/...`) elsewhere.
  String cachePath() => host.paths.context.join(
    host.paths.configRoot,
    'xcross',
    'update_check.json',
  );

  UpdateCheckCache? _read() {
    try {
      final file = host.fileSystem.file(cachePath());
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?>) return null;
      return UpdateCheckCache.fromJson(decoded);
    } on Object {
      return null;
    }
  }

  void _write(String? latest) {
    try {
      final file = host.fileSystem.file(cachePath());
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'checkedAt': DateTime.now().millisecondsSinceEpoch,
          if (latest != null) 'latest': latest,
        }),
      );
    } on Object {
      // A read-only config directory just means no caching.
    }
  }
}

/// Contents of the update-check cache file.
@immutable
final class UpdateCheckCache {
  const UpdateCheckCache({required this.checkedAt, this.latest});

  /// Parses the cache file, tolerating anything a future version may add.
  static UpdateCheckCache? fromJson(Map<String, Object?> json) {
    final checkedAt = json['checkedAt'];
    if (checkedAt is! int) return null;
    final latest = json['latest'];
    return UpdateCheckCache(
      checkedAt: DateTime.fromMillisecondsSinceEpoch(checkedAt),
      latest: latest is String ? latest : null,
    );
  }

  /// When the last successful or failed lookup happened.
  final DateTime checkedAt;

  /// Newest tag seen, or null when the last lookup failed.
  final String? latest;

  /// Whether the entry is old enough to refresh.
  bool get isStale =>
      DateTime.now().difference(checkedAt) >= UpdateCheck.interval;
}
