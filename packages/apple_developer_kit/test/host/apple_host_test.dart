import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_headers.dart';
import 'package:apple_developer_kit/src/host/linux/linux_machine_identity.dart';
import 'package:apple_developer_kit/src/host/macos/macos_machine_identity.dart';
import 'package:apple_developer_kit/src/host/windows/windows_machine_identity.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import '../support/host_services.dart';

void main() {
  test('native loader refuses a mismatched ABI before creating memory', () {
    switch (Abi.current()) {
      case Abi.macosX64 || Abi.macosArm64:
        expect(createLinuxNativeLibraryLoader, throwsUnsupportedError);
        expect(createWindowsNativeLibraryLoader, throwsUnsupportedError);
      case Abi.linuxX64 || Abi.linuxArm64:
        expect(createMacOSNativeLibraryLoader, throwsUnsupportedError);
        expect(createWindowsNativeLibraryLoader, throwsUnsupportedError);
      case Abi.windowsX64:
        expect(createLinuxNativeLibraryLoader, throwsUnsupportedError);
        expect(createMacOSNativeLibraryLoader, throwsUnsupportedError);
      default:
        expect(createLinuxNativeLibraryLoader, throwsUnsupportedError);
        expect(createMacOSNativeLibraryLoader, throwsUnsupportedError);
        expect(createWindowsNativeLibraryLoader, throwsUnsupportedError);
    }
  });

  test('selected hosts own configuration and path identity', () {
    final linux = createLinuxAppleHostServices(
      LinuxHost(
        environment: {
          'HOME': '/home/test',
          'XDG_CONFIG_HOME': '/isolated/config',
        },
        currentDirectory: '/work',
      ),
      localeName: 'en_US',
      abi: Abi.linuxX64,
    );
    final macos = testMacOSAppleHostServices(
      MacOSHost(
        environment: {'HOME': '/Users/test'},
        currentDirectory: '/work',
      ),
      localeName: 'en_US',
      abi: Abi.macosX64,
    );
    final windows = testWindowsAppleHostServices(
      WindowsHost(
        environment: {'APPDATA': r'C:\Users\test\AppData\Roaming'},
        currentDirectory: r'C:\work',
      ),
      localeName: 'en_US',
      abi: Abi.windowsX64,
    );
    expect(xcrossConfigDir(hostServices: linux), '/isolated/config/xcross');
    expect(xcrossConfigDir(hostServices: macos), '/Users/test/.config/xcross');
    expect(
      xcrossConfigDir(hostServices: windows),
      r'C:\Users\test\AppData\Roaming\xcross',
    );
    expect(linux.pathKey('/work/Case'), isNot(linux.pathKey('/work/case')));
    expect(windows.pathKey(r'C:\work\Case'), windows.pathKey(r'C:\WORK\case'));
  });

  test('locale normalization is independent of ambient host', () {
    expect(
      AnisetteHeaders.anisetteSystemLocale(localeName: 'fr-FR.UTF-8'),
      'fr_FR',
    );
    expect(AnisetteHeaders.anisetteSystemLocale(localeName: 'C'), 'en_US');
    final services = createLinuxAppleHostServices(
      LinuxHost(),
      localeName: 'de_DE',
      abi: Abi.linuxX64,
    );
    expect(services.localeName, 'de_DE');
  });

  test('Linux machine identity reads only injected file paths', () async {
    final directory = Directory.systemTemp.createTempSync(
      'apple-host-identity-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final first = File(p.join(directory.path, 'first'))
      ..writeAsStringSync('  ');
    final second = File(p.join(directory.path, 'second'))
      ..writeAsStringSync(' stable-id\n');
    final host = LinuxHost();
    final identity = LinuxMachineIdentity(
      host.fileSystem,
      paths: [first.path, second.path],
    );
    expect(await identity.read(), 'stable-id');
    expect(
      await LinuxMachineIdentity(
        host.fileSystem,
        paths: [p.join(directory.path, 'missing')],
      ).read(),
      '',
    );
  });

  test(
    'macOS identity invokes ioreg through selected process runner',
    () async {
      final runner = IdentityRunner('"IOPlatformUUID" = "mac-id"');
      expect(await MacOSMachineIdentity(runner.run).read(), 'mac-id');
      expect(runner.commands, [
        ['/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice'],
      ]);
    },
  );

  test(
    'Windows identity invokes registry through selected process runner',
    () async {
      final runner = IdentityRunner('MachineGuid    REG_SZ    win-id');
      expect(
        await WindowsMachineIdentity(runner.run, runner.locateTool).read(),
        'win-id',
      );
      expect(runner.commands.single, [
        'reg.exe',
        'query',
        r'HKLM\SOFTWARE\Microsoft\Cryptography',
        '/v',
        'MachineGuid',
      ]);
    },
  );

  test('machine identity failures retain key-file-only fallback', () async {
    final failed = IdentityRunner('', exitCode: 1);
    expect(await MacOSMachineIdentity(failed.run).read(), '');
    expect(
      await WindowsMachineIdentity(failed.run, failed.locateTool).read(),
      '',
    );
  });

  test('cipher uses selected environment identity and permissions', () async {
    final directory = Directory.systemTemp.createTempSync('apple-host-cipher-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final permissions = Permissions();
    final services = AppleHostServices(
      host: LinuxHost(
        environment: {LocalCipher.bindingEnvironmentVariable: 'key-only'},
      ),
      machineIdentity: Identity('machine-a'),
      permissions: permissions,
      abi: Abi.linuxX64,
    );
    final cipher = LocalCipher(
      keyFilePath: p.join(directory.path, 'key'),
      hostServices: services,
    );
    final envelope = await cipher.seal('secret');
    expect(await cipher.open(envelope), 'secret');
    expect(envelope, contains('key-only'));
    expect(permissions.hardened, isNotEmpty);
  });

  test('secure temp is hardened empty before writing secret bytes', () async {
    final directory = Directory.systemTemp.createTempSync(
      'secure-write-order-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final selected = testHostServices;
    final events = <String>[];
    final files = SecureWriteFileSystem(selected.host.fileSystem, (file) {
      events.add('write');
      expect(events, ['harden', 'write']);
      expect(file.readAsBytesSync(), isEmpty);
      if (selected.abi != Abi.windowsX64) {
        expect(file.statSync().mode & 0x1ff, 0x180);
      }
    });
    final services = AppleHostServices(
      host: LinuxHost(fileSystem: files),
      abi: selected.abi,
      machineIdentity: Identity(''),
      permissions: SecureWritePermissions(selected.permissions, (file) {
        events.add('harden');
        expect(file.readAsBytesSync(), isEmpty);
      }),
    );
    final path = p.join(directory.path, 'secret');
    await SecureFile(hostServices: services).writeString(path, 'private-key');
    expect(events, ['harden', 'write']);
    expect(File(path).readAsStringSync(), 'private-key');
    expect(directory.listSync().length, 1);
  });

  test('shared bindings request callable pointers with ABI arity', () {
    final library = RecordingLibrary();
    AdiNativeBindings(library);
    expect(library.arities.values.toList(), [1, 2, 1, 1, 7, 1, 5, 6, 1, 1, 5]);
    expect(library.rawLookups, 0);
  });
}

final class IdentityRunner {
  IdentityRunner(this.output, {this.exitCode = 0});

  final String output;
  final int exitCode;
  final List<List<String>> commands = [];

  Future<String> locateTool(
    String name, {
    Iterable<String> extraDirectories = const [],
  }) async => '$name.exe';

  Future<CapturedProcess> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    commands.add([executable, ...arguments]);
    return CapturedProcess(exitCode, output, '');
  }
}

final class Permissions implements AppleFilePermissions {
  final List<String> hardened = [];

  @override
  void harden(String path) => hardened.add(path);

  @override
  void preserve(String path, int mode) {}
}

final class Identity implements MachineIdentityProvider {
  Identity(this.value);
  final String value;
  @override
  Future<String> read() async => value;
}

final class RecordingLibrary implements LoadedNativeLibrary {
  final Map<String, int> arities = {};
  int rawLookups = 0;

  @override
  Pointer<NativeFunction<T>> callable<T extends Function>(
    String symbolName,
    int argumentCount,
  ) {
    arities[symbolName] = argumentCount;
    return Pointer.fromAddress(1);
  }

  @override
  Pointer<NativeFunction<T>> lookup<T extends Function>(String symbolName) {
    rawLookups++;
    return Pointer.fromAddress(1);
  }
}

final class SecureWritePermissions implements AppleFilePermissions {
  SecureWritePermissions(this.delegate, this.onHarden);
  final AppleFilePermissions delegate;
  final void Function(File) onHarden;
  @override
  void harden(String path) {
    onHarden(File(path));
    delegate.harden(path);
  }

  @override
  void preserve(String path, int mode) => delegate.preserve(path, mode);
}

final class SecureWriteFileSystem implements HostFileSystemInterface {
  SecureWriteFileSystem(this.delegate, this.onWrite);
  final HostFileSystemInterface delegate;
  final void Function(File) onWrite;
  @override
  File file(String path) => path.endsWith('.tmp')
      ? SecureWriteFile(delegate.file(path), onWrite)
      : delegate.file(path);
  @override
  Directory directory(String path) => delegate.directory(path);
  @override
  Link link(String path) => delegate.link(path);
  @override
  void makeExecutable(String path) => delegate.makeExecutable(path);
  @override
  void setPermissions(String path, int mode) =>
      delegate.setPermissions(path, mode);
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      delegate.createArchiveLink(destination, target);
}

final class SecureWriteFile implements File {
  SecureWriteFile(this.delegate, this.onWrite);
  final File delegate;
  final void Function(File) onWrite;
  @override
  String get path => delegate.path;
  @override
  Directory get parent => delegate.parent;
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) =>
      delegate.create(recursive: recursive, exclusive: exclusive);
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) {
    onWrite(delegate);
    return delegate.writeAsBytes(bytes, mode: mode, flush: flush);
  }

  @override
  Future<File> rename(String newPath) => delegate.rename(newPath);
  @override
  bool existsSync() => delegate.existsSync();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      delegate.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
