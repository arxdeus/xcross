import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sdk_log_test_support.dart';

void main() {
  late Directory tmp;
  late DarwinToolchainTestIo io;
  late MacOSHost host;
  late Log log;
  late DarwinToolchainResolver<MacOSHost> resolver;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross-sdk-fixture-');
    host = MacOSHost(temporaryDirectory: tmp.path);
    log = sdkTestLog();
    io = DarwinToolchainTestIo();
    resolver = DarwinToolchainResolver(
      ProcessRunner(
        host,
        log: log,
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      ),
      MacOSDarwinToolchainLocations(host),
    );
  });
  tearDown(() async {
    await io.close();
    await tmp.delete(recursive: true);
  });

  group('probeDarwinDriver', () {
    test('accepts a driver that only misses its input file', () async {
      final failure = await resolver.probeDarwinDriver(
        p.join(tmp.path, 'good-clang'),
        sysroot: tmp.path,
        runProcess: (executable, arguments) async => const CapturedProcess(
          1,
          '',
          "clang: error: no such file or directory: 'probe.c'",
        ),
      );
      expect(failure, isNull);
    });

    test('rejects a driver that fast-fails on the sysroot', () async {
      final failure = await resolver.probeDarwinDriver(
        p.join(tmp.path, 'swift-clang'),
        sysroot: tmp.path,
        runProcess: (executable, arguments) async =>
            const CapturedProcess(-1073740791, '', ''),
      );
      expect(failure, allOf(contains('crashed'), contains('0xC0000409')));
    });

    test('keeps probe verdicts separate for different SDK roots', () async {
      var runs = 0;
      Future<CapturedProcess> run(
        String executable,
        List<String> arguments,
      ) async {
        runs++;
        return CapturedProcess(
          arguments.contains('bad-sdk') ? -1073740791 : 1,
          '',
          '',
        );
      }

      expect(
        await resolver.probeDarwinDriver(
          'same-clang',
          sysroot: 'bad-sdk',
          runProcess: run,
        ),
        contains('crashed'),
      );
      expect(
        await resolver.probeDarwinDriver(
          'same-clang',
          sysroot: 'bad-sdk',
          runProcess: run,
        ),
        contains('crashed'),
      );
      expect(
        await resolver.probeDarwinDriver(
          'same-clang',
          sysroot: 'good-sdk',
          runProcess: run,
        ),
        isNull,
      );
      expect(
        await resolver.probeDarwinDriver(
          'same-clang',
          sysroot: 'good-sdk',
          runProcess: run,
        ),
        isNull,
      );
      expect(runs, 2);
    });

    test('does not share version cache across resolver instances', () async {
      final otherIo = DarwinToolchainTestIo();
      addTearDown(otherIo.close);
      final other = DarwinToolchainResolver(
        ProcessRunner(
          host,
          log: log,
          stdinStream: otherIo.input,
          stdoutSink: otherIo.output,
          stderrSink: otherIo.error,
        ),
        MacOSDarwinToolchainLocations(host),
      );
      expect(
        await resolver.clangMajorVersion(
          'same-clang',
          runProcess: (_, _) async =>
              const CapturedProcess(0, 'clang version 18.0', ''),
        ),
        18,
      );
      expect(
        await other.clangMajorVersion(
          'same-clang',
          runProcess: (_, _) async =>
              const CapturedProcess(0, 'clang version 21.0', ''),
        ),
        21,
      );
    });

    test('drives the probe without running any subcommand', () async {
      late List<String> seen;
      await resolver.probeDarwinDriver(
        p.join(tmp.path, 'recorded-clang'),
        sysroot: p.join(tmp.path, 'iPhoneOS26.5.sdk'),
        runProcess: (executable, arguments) async {
          seen = arguments;
          return const CapturedProcess(1, '', 'no such file');
        },
      );
      expect(seen.first, '-###');
      expect(
        seen,
        containsAllInOrder(['-isysroot', p.join(tmp.path, 'iPhoneOS26.5.sdk')]),
      );
    });
  });

  group('clang version vs SDK libc++', () {
    test('derives the minimum clang from the SDK libc++ version', () {
      final include = Directory(p.join(tmp.path, 'usr', 'include', 'c++', 'v1'))
        ..createSync(recursive: true);
      File(
        p.join(include.path, '__config'),
      ).writeAsStringSync('#  define _LIBCPP_VERSION 210106\n');
      expect(resolver.minimumClangForSdk(tmp.path), 19);
    });

    test('has no minimum without libc++ headers', () {
      expect(resolver.minimumClangForSdk(tmp.path), isNull);
    });

    test('flags an LLVM clang older than the minimum', () async {
      final reason = await resolver.clangTooOldForSdk(
        p.join(tmp.path, 'clang-18'),
        minimum: 19,
        runProcess: (_, _) async => const CapturedProcess(
          0,
          'Ubuntu clang version 18.1.3 (1ubuntu1)\n',
          '',
        ),
      );
      expect(reason, allOf(contains('clang 18'), contains('clang 19')));
    });

    test('accepts a new enough clang and Apple clang', () async {
      expect(
        await resolver.clangTooOldForSdk(
          p.join(tmp.path, 'clang-21'),
          minimum: 19,
          runProcess: (_, _) async =>
              const CapturedProcess(0, 'clang version 21.0.0 (swift)\n', ''),
        ),
        isNull,
      );
      expect(
        await resolver.clangTooOldForSdk(
          p.join(tmp.path, 'apple-clang'),
          minimum: 19,
          runProcess: (_, _) async => const CapturedProcess(
            0,
            'Apple clang version 17.0.0 (clang-1700.0.13.3)\n',
            '',
          ),
        ),
        isNull,
      );
    });
  });

  group('llvmToolDirs', () {
    test('covers both Windows LLVM installer layouts', () {
      final dirs = WindowsDarwinToolchainLocations(
        WindowsHost(
          environment: {
            'ProgramFiles': r'C:\Program Files',
            'LOCALAPPDATA': r'C:\Users\Mind\AppData\Local',
          },
        ),
      ).llvmToolDirectories();
      expect(dirs, [
        r'C:\Program Files\LLVM\bin',
        r'C:\Users\Mind\AppData\Local\Programs\LLVM\bin',
      ]);
    });

    test('skips roots the environment does not define', () {
      expect(
        WindowsDarwinToolchainLocations(WindowsHost()).llvmToolDirectories(),
        isEmpty,
      );
    });

    test('keeps Linux versioned LLVM discovery separate from Homebrew', () {
      for (final version in ['18', '22', '19.1']) {
        Directory(p.join(tmp.path, 'llvm-$version')).createSync();
      }
      Directory(p.join(tmp.path, 'unrelated')).createSync();
      final linux = LinuxHost(fileSystem: FixtureFileSystem(tmp.path));
      expect(LinuxDarwinToolchainLocations(linux).llvmToolDirectories(), [
        '/usr/lib/llvm-22/bin',
        '/usr/lib/llvm-19.1/bin',
        '/usr/lib/llvm-18/bin',
      ]);
    });

    test('covers Homebrew lld and llvm prefixes', () {
      expect(
        MacOSDarwinToolchainLocations(host).llvmToolDirectories(),
        containsAll([
          '/opt/homebrew/opt/lld/bin',
          '/opt/homebrew/opt/llvm/bin',
          '/usr/local/opt/lld/bin',
          '/usr/local/opt/llvm/bin',
        ]),
      );
    });
  });

  group('probeIosSupport', () {
    test('accepts a linker that only misses its input file', () async {
      final failure = await resolver.probeIosSupport(
        p.join(tmp.path, 'good-ld64.lld'),
        runProcess: (executable, arguments) async => const CapturedProcess(
          1,
          '',
          'ld64.lld: error: cannot open xcross-ld64-probe.o: No such file',
        ),
      );
      expect(failure, isNull);
    });

    test('rejects a linker that refuses the iOS platform', () async {
      final failure = await resolver.probeIosSupport(
        p.join(tmp.path, 'swift-ld64.lld'),
        runProcess: (executable, arguments) async => const CapturedProcess(
          1,
          '',
          'ld64.lld: error: This version of lld does not support linking for '
              'platform iOS',
        ),
      );
      expect(failure, contains('does not support linking for platform iOS'));
    });

    test('rejects a linker without ARM64 Mach-O support', () async {
      final failure = await resolver.probeIosSupport(
        p.join(tmp.path, 'unsupported-arch-ld64.lld'),
        runProcess: (executable, arguments) async => const CapturedProcess(
          1,
          '',
          'ld64.lld: error: missing or unsupported -arch arm64',
        ),
      );
      expect(failure, contains('missing or unsupported -arch arm64'));
    });

    test('rejects a linker that dies without saying anything', () async {
      final failure = await resolver.probeIosSupport(
        p.join(tmp.path, 'crashing-ld64.lld'),
        runProcess: (executable, arguments) async =>
            const CapturedProcess(-1073740791, '', ''),
      );
      expect(failure, allOf(contains('crashed'), contains('0xC0000409')));
    });

    test('probes each linker once', () async {
      var runs = 0;
      final linker = p.join(tmp.path, 'counted-ld64.lld');
      Future<CapturedProcess> run(String executable, List<String> arguments) {
        runs++;
        return Future.value(
          const CapturedProcess(1, '', 'ld64.lld: error: cannot open'),
        );
      }

      await resolver.probeIosSupport(linker, runProcess: run);
      await resolver.probeIosSupport(linker, runProcess: run);
      expect(runs, 1);
    });

    test('asks the linker for an iOS dylib', () async {
      late List<String> seen;
      await resolver.probeIosSupport(
        p.join(tmp.path, 'recorded-ld64.lld'),
        runProcess: (executable, arguments) async {
          seen = arguments;
          return const CapturedProcess(1, '', 'cannot open');
        },
      );
      expect(
        seen,
        containsAllInOrder(['-platform_version', 'ios', '13.0', '13.0']),
      );
      expect(seen, contains('-dylib'));
    });
  });

  group('selectorStubDefect', () {
    Future<CapturedProcess> Function(String, List<String>) version(
      String banner,
    ) => (executable, arguments) async {
      expect(arguments, ['--version']);
      return CapturedProcess(0, banner, '');
    };

    test('parses distribution-prefixed and plain banners', () async {
      expect(
        await resolver.ld64LldVersion(
          p.join(tmp.path, 'ubuntu-ld64.lld'),
          runProcess: version(
            'Ubuntu LLD 18.1.3 (compatible with Apple linkers)\n',
          ),
        ),
        (18, 1),
      );
      expect(
        await resolver.ld64LldVersion(
          p.join(tmp.path, 'brew-ld64.lld'),
          runProcess: version('Homebrew LLD 22.1.8\n'),
        ),
        (22, 1),
      );
      expect(
        await resolver.ld64LldVersion(
          p.join(tmp.path, 'swift-ld64.lld'),
          runProcess: version(
            'LLD 21.0.0 (https://github.com/swiftlang/llvm-project.git abc)\n',
          ),
        ),
        (21, 0),
      );
    });

    test('flags lld 18 and accepts lld 19', () async {
      expect(
        await resolver.selectorStubDefect(
          p.join(tmp.path, 'lld18'),
          runProcess: version(
            'Ubuntu LLD 18.1.3 (compatible with Apple linkers)',
          ),
        ),
        allOf(contains('18.1'), contains('selector stubs')),
      );
      expect(
        await resolver.selectorStubDefect(
          p.join(tmp.path, 'lld19'),
          runProcess: version(
            'Ubuntu LLD 19.1.1 (compatible with Apple linkers)',
          ),
        ),
        isNull,
      );
    });

    test('does not hold an unreadable version against a linker', () async {
      expect(
        await resolver.selectorStubDefect(
          p.join(tmp.path, 'silent'),
          runProcess: version(''),
        ),
        isNull,
      );
      expect(
        await resolver.selectorStubDefect(
          p.join(tmp.path, 'broken'),
          runProcess: (executable, arguments) => throw StateError('no'),
        ),
        isNull,
      );
    });

    test('asks each linker for its version once', () async {
      var runs = 0;
      final linker = p.join(tmp.path, 'counted');
      Future<CapturedProcess> run(String executable, List<String> arguments) {
        runs++;
        return Future.value(const CapturedProcess(0, 'LLD 20.1.0', ''));
      }

      await resolver.selectorStubDefect(linker, runProcess: run);
      await resolver.selectorStubDefect(linker, runProcess: run);
      expect(runs, 1);
    });
  });
}

final class FixtureFileSystem implements HostFileSystemInterface {
  const FixtureFileSystem(this.root);
  final String root;
  String _path(String path) => path == '/usr/lib' ? root : path;
  @override
  File file(String path) => File(_path(path));
  @override
  Directory directory(String path) => Directory(_path(path));
  @override
  Link link(String path) => Link(_path(path));
  @override
  void makeExecutable(String path) {}
  @override
  void setPermissions(String path, int mode) {}
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      link(destination).create(target);
}

final class DarwinToolchainTestIo {
  DarwinToolchainTestIo() {
    outputController.stream.listen((_) {});
    errorController.stream.listen((_) {});
    output = IOSink(outputController.sink);
    error = IOSink(errorController.sink);
  }

  final Stream<List<int>> input = const Stream<List<int>>.empty();
  final StreamController<List<int>> outputController =
      StreamController<List<int>>();
  final StreamController<List<int>> errorController =
      StreamController<List<int>>();
  late final IOSink output;
  late final IOSink error;

  Future<void> close() async {
    await Future.wait([output.close(), error.close()]);
  }
}
