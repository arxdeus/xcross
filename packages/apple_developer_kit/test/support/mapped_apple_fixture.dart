import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

@internal
final class MappedAppleFixture {
  MappedAppleFixture() {
    root = Directory.systemTemp.createTempSync('apple-residual-mapped-');
    logicalRoot = p.join(root.path, 'logical');
    backingRoot = p.join(root.path, 'backing');
    Directory(logicalRoot).createSync();
    Directory(backingRoot).createSync();
    fileSystem = MappedAppleFileSystem(logicalRoot, backingRoot);
    permissions = RecordingApplePermissions();
    services = AppleHostServices(
      host: MappedAppleHost(
        LinuxHost(currentDirectory: logicalRoot),
        fileSystem,
        MappedApplePaths(logicalRoot),
      ),
      abi: Abi.linuxArm64,
      machineIdentity: FixedAppleMachineIdentity(),
      permissions: permissions,
    );
  }

  late final Directory root;
  late final String logicalRoot;
  late final String backingRoot;
  late final MappedAppleFileSystem fileSystem;
  late final RecordingApplePermissions permissions;
  late final AppleHostServices services;

  String path(String relative) => p.join(logicalRoot, relative);
  String logicalPath(String physical) =>
      path(p.relative(physical, from: backingRoot));
  void dispose() => root.deleteSync(recursive: true);
}

@internal
final class MappedAppleHost implements PlatformHostInterface {
  MappedAppleHost(this.base, this.fileSystem, this.paths);

  final PlatformHostInterface base;
  @override
  final HostFileSystemInterface fileSystem;
  @override
  final HostPathsInterface paths;
  @override
  String get name => base.name;
  @override
  String get architecture => base.architecture;
  @override
  HostEnvironmentInterface get environment => base.environment;
  @override
  HostProcessInterface get processes => base.processes;
}

@internal
final class MappedApplePaths implements HostPathsInterface {
  MappedApplePaths(this.root) : context = p.Context(style: p.Style.posix);
  @override
  String toolNameKey(String name) => name.trim();

  final String root;
  @override
  final p.Context context;
  @override
  String get configRoot => context.join(root, 'config');
  @override
  String get cacheRoot => context.join(root, 'cache');
  @override
  String get temporaryRoot => context.join(root, 'tmp');
  @override
  String ioPath(String path) => path;
  @override
  String pathKey(String path) => context.normalize(path);
  @override
  String executableName(String name, {String extension = '.exe'}) => name;
}

@internal
final class MappedAppleFileSystem implements HostFileSystemInterface {
  MappedAppleFileSystem(this.logicalRoot, this.backingRoot);

  final String logicalRoot;
  final String backingRoot;
  final List<String> acquisitions = [];

  String mapped(String path) {
    if (!p.isWithin(logicalRoot, path) && path != logicalRoot) {
      throw StateError('Expected logical acquisition, got $path');
    }
    acquisitions.add(path);
    return p.join(backingRoot, p.relative(path, from: logicalRoot));
  }

  @override
  File file(String path) => File(mapped(path));
  @override
  Directory directory(String path) => Directory(mapped(path));
  @override
  Link link(String path) => Link(mapped(path));
  @override
  void makeExecutable(String path) => throw StateError('Unexpected chmod');
  @override
  void setPermissions(String path, int mode) =>
      throw StateError('Unexpected chmod');
  @override
  Future<void> createArchiveLink(String destination, String target) async =>
      throw StateError('Unexpected archive link');
}

@internal
final class RecordingApplePermissions implements AppleFilePermissions {
  final List<String> hardened = [];
  final List<(String, int)> preserved = [];
  @override
  void harden(String path) => hardened.add(path);
  @override
  void preserve(String path, int mode) => preserved.add((path, mode));
}

@internal
final class FixedAppleMachineIdentity implements MachineIdentityProvider {
  @override
  Future<String> read() async => 'mapped-apple-machine';
}
