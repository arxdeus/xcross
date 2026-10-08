import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/cli/basic/auth_command.dart';

import '../log_fixture.dart';
import 'runtime_fixture.dart';

@internal
AuthCommand authFixture({
  AppleHostServices? services,
  Abi abi = Abi.linuxX64,
  http.Client Function()? createAdiHttpClient,
}) {
  final base = services ?? testRuntime().appleHostServices;
  return AuthCommand(
    log: testLog(),
    commandPrompt: TestCommandPrompt(),
    hostServices: AppleHostServices(
      host: base.host,
      abi: abi,
      machineIdentity: base.machineIdentity,
      permissions: base.permissions,
    ),
    createAdiHttpClient:
        createAdiHttpClient ?? () => throw StateError('Unexpected ADI HTTP'),
    createHttpClient: () => throw StateError('Unexpected Apple HTTP'),
    createNativeLibraryLoader: () =>
        throw StateError('Unexpected native loader'),
  );
}

@internal
final class AuthNamespaceFixture {
  AuthNamespaceFixture({required p.Style style}) {
    backing = Directory.systemTemp.createTempSync('xcross-auth-mapped-');
    logicalRoot = style == p.Style.windows ? r'C:\selected' : '/selected';
    paths = AuthNamespacePaths(p.Context(style: style, current: logicalRoot));
    fileSystem = AuthNamespaceFileSystem(
      paths.context,
      logicalRoot,
      backing.path,
    );
    host = AuthNamespaceHost(
      LinuxHost(environment: {'HOME': logicalRoot}),
      paths,
      fileSystem,
    );
    services = AppleHostServices(
      host: host,
      abi: Abi.linuxX64,
      machineIdentity: const AuthNamespaceIdentity(),
      permissions: AuthNamespacePermissions(),
    );
  }

  late final Directory backing;
  late final String logicalRoot;
  late final AuthNamespacePaths paths;
  late final AuthNamespaceFileSystem fileSystem;
  late final AuthNamespaceHost host;
  late final AppleHostServices services;

  String path(String name) => paths.context.join(logicalRoot, name);
  void dispose() => backing.deleteSync(recursive: true);
}

@internal
final class AuthNamespaceFileSystem implements HostFileSystemInterface {
  AuthNamespaceFileSystem(this.paths, this.logicalRoot, this.backingRoot);
  final p.Context paths;
  final String logicalRoot;
  final String backingRoot;
  final List<String> acquisitions = [];

  String mapped(String value) {
    if (value != logicalRoot && !paths.isWithin(logicalRoot, value)) {
      throw StateError('Not a selected logical path: $value');
    }
    acquisitions.add(value);
    return p.joinAll([
      backingRoot,
      ...paths
          .split(paths.relative(value, from: logicalRoot))
          .where((part) => part != '.'),
    ]);
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
      throw StateError('Unexpected link');
}

@internal
final class AuthNamespacePaths implements HostPathsInterface {
  const AuthNamespacePaths(this.context);
  @override
  String toolNameKey(String name) => name.trim();
  @override
  final p.Context context;
  @override
  String get configRoot => context.join(context.current, 'config');
  @override
  String get cacheRoot => context.join(context.current, 'cache');
  @override
  String get temporaryRoot => context.join(context.current, 'tmp');
  @override
  String ioPath(String path) => path;
  @override
  String pathKey(String path) => context.normalize(path);
  @override
  String executableName(String name, {String extension = '.exe'}) => name;
}

@internal
final class AuthNamespaceHost implements PlatformHostInterface {
  AuthNamespaceHost(this.base, this.paths, this.fileSystem);
  final PlatformHostInterface base;
  @override
  final HostPathsInterface paths;
  @override
  final HostFileSystemInterface fileSystem;
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
final class AuthNamespaceIdentity implements MachineIdentityProvider {
  const AuthNamespaceIdentity();
  @override
  Future<String> read() async => 'auth-fixture-machine';
}

@internal
final class AuthNamespacePermissions implements AppleFilePermissions {
  final List<String> hardened = [];
  @override
  void harden(String path) => hardened.add(path);
  @override
  void preserve(String path, int mode) => throw StateError('Unexpected mode');
}
