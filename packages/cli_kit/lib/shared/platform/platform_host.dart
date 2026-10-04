import 'dart:io';

import 'package:path/path.dart' as p;

abstract interface class PlatformHostInterface {
  String get name;
  String get architecture;
  HostPathsInterface get paths;
  HostEnvironmentInterface get environment;
  HostProcessInterface get processes;
  HostFileSystemInterface get fileSystem;
}

abstract interface class WindowsHostInterface
    implements PlatformHostInterface {}

abstract interface class LinuxHostInterface implements PlatformHostInterface {}

abstract interface class MacOSHostInterface implements PlatformHostInterface {}

abstract interface class HostPathsInterface {
  p.Context get context;
  String get configRoot;
  String get cacheRoot;
  String get temporaryRoot;
  String ioPath(String path);
  String executableName(String name, {String extension = '.exe'});
  String pathKey(String path);
}

abstract interface class HostEnvironmentInterface {
  Map<String, String> get values;
  String? lookup(Map<String, String> environment, String key);
  Map<String, String> overlay(
    Map<String, String> base,
    Map<String, String> overrides,
  );
  List<String> splitPathList(String value);
  String joinPathList(Iterable<String> values);
  List<String> executableCandidates(
    String name,
    Map<String, String> environment,
  );
}

abstract interface class HostProcessInterface {
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  });
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  });
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  });
}

abstract interface class HostFileSystemInterface {
  File file(String path);
  Directory directory(String path);
  Link link(String path);
  void makeExecutable(String path);
  void setPermissions(String path, int mode);
  Future<void> createArchiveLink(String destination, String target);
}

abstract interface class HostPrivilegesInterface {
  Future<void> ensureElevated({String? manualHint, String? deniedMessage});
  Future<String?> resolve();
  Future<void> cacheCredentials({String? manualHint});
}

abstract interface class HostPermissionsInterface {
  void setPermissions(String path, int mode);
}
