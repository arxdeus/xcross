import 'dart:ffi';
import 'dart:io';
import 'package:cli_kit/cli_kit.dart' show PlatformHostInterface;

abstract interface class MachineIdentityProvider {
  Future<String> read();
}

abstract interface class AppleFilePermissions {
  void harden(String path);
  void preserve(String path, int mode);
}

final class AppleHostServices {
  const AppleHostServices({
    required this.host,
    required this.abi,
    required this.machineIdentity,
    required this.permissions,
    this.localeName = 'en_US',
  });

  final Abi abi;
  final String localeName;
  final PlatformHostInterface host;
  final MachineIdentityProvider machineIdentity;
  final AppleFilePermissions permissions;

  String get configDirectory =>
      host.paths.context.join(host.paths.configRoot, 'xcross');
  Directory get adiCacheDirectory {
    final environment = host.environment.values;
    final home = environment['HOME'] ?? environment['USERPROFILE'];
    if (home == null) {
      throw StateError('Cannot determine a home directory (HOME is not set).');
    }
    return host.fileSystem.directory(
      host.paths.context.join(home, '.cache', 'provision_dart'),
    );
  }

  String pathKey(String path) => host.paths.pathKey(path);
}
