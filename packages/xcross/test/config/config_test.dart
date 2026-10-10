import 'dart:io';

import 'package:cli_kit/composition/native_host.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/config/posix_config_host.dart';
import 'package:xcross/src/host/windows/config/windows_config_host.dart';
import 'package:xcross/src/shared/config/config.dart';
import 'package:xcross/src/shared/config/config_decoder.dart';
import 'package:xcross/src/shared/config/config_store.dart';

import '../cli/auth_fixture.dart';

void main() {
  late Directory temporary;

  setUp(
    () => temporary = Directory.systemTemp.createTempSync('xcross-config-'),
  );
  tearDown(() => temporary.deleteSync(recursive: true));

  const valid = '''
roots:
  darwinSdk: /opt/darwin
  flutterSdk: ~/flutter
  xcross: /opt/xcross/bin/xcross
  javaHome: /opt/jdk
  konanData: /opt/konan
toolchains:
  swift: /opt/swift/bin
  llvm:
    - /opt/llvm/bin
    - /opt/llvm-extra/bin
tools: {}
setup: https://example.com/setup.sh
excluded_commands:
  - setup
  - config
environment:
  PATH:
    - /opt/bin
    - ~/bin
  JAVA_HOME: /opt/jdk
  LIBRARY_PATH: /opt/lib
  C_INCLUDE_PATH: /opt/include
  CPLUS_INCLUDE_PATH: /opt/cpp/include
''';

  test('parses optional agreed roots and typed allowlisted environment', () {
    final config = XcrossConfig.parse(
      valid,
      environment: const {'HOME': '/home/test'},
      host: LinuxHost(),
      policy: const PosixConfigHost(),
    );

    expect(config.roots.flutterSdk, '/home/test/flutter');
    expect(config.roots.darwinSdk, '/opt/darwin');
    expect(config.roots.xcross, '/opt/xcross/bin/xcross');
    expect(config.roots.javaHome, '/opt/jdk');
    expect(config.roots.konanData, '/opt/konan');
    expect(config.toolchains.swift, '/opt/swift/bin');
    expect(config.toolchains.llvm, ['/opt/llvm/bin', '/opt/llvm-extra/bin']);
    expect(config.environment['PATH'], ['/opt/bin', '/home/test/bin']);
    expect(config.environment['LIBRARY_PATH'], '/opt/lib');
    expect(config.setup, 'https://example.com/setup.sh');
    expect(config.excludedCommands, {'setup', 'config'});
  });

  test('copyWith preserves immutable values and can clear nullable fields', () {
    final original = XcrossConfig(
      roots: const XcrossConfigRoots(
        darwinSdk: '/opt/darwin',
        flutterSdk: '/opt/flutter',
      ),
      setup: '/opt/setup.sh',
      excludedCommands: const ['config'],
    );

    final updated = original.copyWith(
      roots: original.roots.copyWith(flutterSdk: null),
      setup: null,
    );

    expect(updated.roots.darwinSdk, '/opt/darwin');
    expect(updated.roots.flutterSdk, isNull);
    expect(updated.setup, isNull);
    expect(updated.excludedCommands, {'config'});
    expect(() => updated.excludedCommands.add('setup'), throwsUnsupportedError);
  });

  test(
    'allows roots and operation-specific roots to be omitted while parsing',
    () {
      expect(
        XcrossConfig.parse(
          '{}',
          environment: const {},
          host: LinuxHost(),
          policy: const PosixConfigHost(),
        ).roots.toMap(),
        isEmpty,
      );
      expect(
        XcrossConfig.parse(
          'roots:\n  flutterSdk: /opt/flutter\n',
          environment: const {},
          host: LinuxHost(),
          policy: const PosixConfigHost(),
        ).roots.flutterSdk,
        '/opt/flutter',
      );
    },
  );

  test(
    'rejects old root names, scalar PATH, list scalar env, and unsafe keys',
    () {
      for (final source in [
        'roots:\n  flutter: /opt/flutter\n',
        'environment:\n  PATH: /opt/bin\n',
        'environment:\n  JAVA_HOME: [/opt/jdk]\n',
        'environment:\n  XDG_CONFIG_HOME: /tmp/config\n',
        'environment:\n  XDG_CACHE_HOME: /tmp/cache\n',
        'environment:\n  APPDATA: /tmp/config\n',
        'environment:\n  XDG_STATE_HOME: /tmp/state\n',
        'environment:\n  TMPDIR: /tmp\n',
      ]) {
        expect(
          () => XcrossConfig.parse(
            source,
            environment: const {},
            host: LinuxHost(),
            policy: const PosixConfigHost(),
          ),
          throwsA(isA<XcrossConfigException>()),
          reason: source,
        );
      }
    },
  );

  test('expands native syntax recursively with injected environment', () {
    expect(
      expandNativeEnvironment(
        r'~/sdk/$ROOT/${JAVA_HOME}/%APPDATA%',
        environment: const {
          'HOME': '/h',
          'ROOT': r'$HOME/root',
          'JAVA_HOME': '/j',
        },
        host: LinuxHost(),
        policy: const PosixConfigHost(),
      ),
      '/h/sdk//h/root//j/%APPDATA%',
    );
    expect(
      expandNativeEnvironment(
        r'C:\%USERPROFILE%\$HOME',
        environment: const {'USERPROFILE': r'C:\Users\me'},
        host: WindowsHost(),
        policy: const WindowsConfigHost(),
      ),
      r'C:\C:\Users\me\$HOME',
    );
    expect(
      () => expandNativeEnvironment(
        r'$A',
        environment: const {'A': r'$B', 'B': r'$A'},
        host: LinuxHost(),
        policy: const PosixConfigHost(),
      ),
      throwsA(isA<XcrossConfigException>()),
    );
    expect(
      () => expandNativeEnvironment(
        r'$MISSING',
        environment: const {},
        host: LinuxHost(),
        policy: const PosixConfigHost(),
      ),
      throwsA(isA<XcrossConfigException>()),
    );
  });

  test('configured child allowlist excludes expansion-only variables', () {
    expect(XcrossConfig.environmentAllowlist, {
      'PATH',
      'CC',
      'CXX',
      'SWIFT_EXEC',
      'SWIFT_EXEC_MANIFEST',
      'JAVA_HOME',
      'FLUTTER_ROOT',
      'KONAN_DATA_DIR',
      'LIBRARY_PATH',
      'C_INCLUDE_PATH',
      'CPLUS_INCLUDE_PATH',
    });
    expect(
      () => XcrossConfig.parse(
        'environment:\n  HOME: /home/child\n',
        environment: const {},
        host: LinuxHost(),
        policy: const PosixConfigHost(),
      ),
      throwsA(isA<XcrossConfigException>()),
    );
  });

  test('parse rejects unsafe and relative path values', () {
    for (final source in [
      'roots:\n  flutterSdk: relative/flutter\n',
      'toolchains:\n  swift: relative/bin\n',
      'toolchains:\n  llvm: [relative/bin]\n',
      'tools:\n  clang: relative/clang\n',
      'environment:\n  PATH: [relative/bin]\n',
      'environment:\n  CC: "bad\\nvalue"\n',
      'environment:\n  CXX: "bad\\u0000value"\n',
      'excluded_commands: setup\n',
      'excluded_commands: ["bad command"]\n',
      'setup: relative/setup.sh\n',
    ]) {
      expect(
        () => XcrossConfig.parse(
          source,
          environment: const {},
          host: LinuxHost(),
          policy: const PosixConfigHost(),
        ),
        throwsA(isA<XcrossConfigException>()),
        reason: source,
      );
    }
  });

  test(
    'validate requires absolute roots but permits absent root directories',
    () {
      XcrossConfigValidator(
        fileSystem: LinuxHost().fileSystem,
        pathContext: LinuxHost().paths.context,
        policy: const PosixConfigHost(),
      ).validate(
        XcrossConfig(
          roots: const XcrossConfigRoots(flutterSdk: '/missing/flutter'),
        ),
      );

      expect(
        () =>
            XcrossConfigValidator(
              fileSystem: LinuxHost().fileSystem,
              pathContext: LinuxHost().paths.context,
              policy: const PosixConfigHost(),
            ).validate(
              XcrossConfig(
                roots: const XcrossConfigRoots(flutterSdk: 'relative/flutter'),
              ),
            ),
        throwsA(isA<XcrossConfigException>()),
      );
    },
  );

  test('accepts scalar llvm and rejects unknown or malformed toolchains', () {
    expect(
      XcrossConfig.parse(
        'toolchains:\n  llvm: /opt/llvm/bin\n',
        environment: const {},
        host: LinuxHost(),
        policy: const PosixConfigHost(),
      ).toolchains.llvm,
      ['/opt/llvm/bin'],
    );
    for (final source in [
      'toolchains:\n  gcc: /opt/gcc/bin\n',
      'toolchains:\n  swift: [/one, /two]\n',
      'toolchains:\n  llvm: 42\n',
    ]) {
      expect(
        () => XcrossConfig.parse(
          source,
          environment: const {},
          host: LinuxHost(),
          policy: const PosixConfigHost(),
        ),
        throwsA(isA<XcrossConfigException>()),
      );
    }
  });

  for (final style in [p.Style.posix, p.Style.windows]) {
    test('tool validation acquires selected file stat on $style', () {
      final fixture = AuthNamespaceFixture(style: style);
      addTearDown(fixture.dispose);
      final tool = fixture.path('tool.exe');
      fixture.fileSystem.file(tool).writeAsStringSync('fixture');
      final decoder = XcrossConfigDecoder(
        document: {
          'tools': {'tool': tool},
        },
        sourcePath: null,
        environment: const {},
        host: fixture.host,
        policy: const WindowsConfigHost(),
      );
      fixture.fileSystem.acquisitions.clear();
      expect(decoder.decode().tool('tool'), tool);
      expect(fixture.fileSystem.acquisitions, [tool]);
      fixture.fileSystem.file(tool).deleteSync();
      expect(decoder.decode, throwsA(isA<XcrossConfigException>()));
      fixture.fileSystem.directory(tool).createSync();
      expect(decoder.decode, throwsA(isA<XcrossConfigException>()));
    });
  }

  test('validate requires tools to be regular executable files', () {
    final executable = File(
      p.join(temporary.path, Platform.isWindows ? 'tool.exe' : 'tool'),
    )..writeAsStringSync('#!/bin/sh\n');
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['755', executable.path]);
    }
    XcrossConfigValidator(
      fileSystem: detectPlatformHost().fileSystem,
      pathContext: detectPlatformHost().paths.context,
      policy: const PosixConfigHost(),
    ).validate(XcrossConfig(tools: {'tool': executable.path}));

    final plain = File(p.join(temporary.path, 'plain'))
      ..writeAsStringSync('plain');
    expect(
      () => XcrossConfigValidator(
        fileSystem: LinuxHost().fileSystem,
        pathContext: LinuxHost().paths.context,
        policy: const PosixConfigHost(),
      ).validate(XcrossConfig(tools: {'plain': plain.path})),
      throwsA(isA<XcrossConfigException>()),
    );
    expect(
      () =>
          XcrossConfigValidator(
            fileSystem: detectPlatformHost().fileSystem,
            pathContext: detectPlatformHost().paths.context,
            policy: const PosixConfigHost(),
          ).validate(
            XcrossConfig(tools: {'missing': p.join(temporary.path, 'missing')}),
          ),
      throwsA(isA<XcrossConfigException>()),
    );
  });

  test('model preserves literal tool keys and immutable copies', () {
    final tools = {'clang': '/one', 'CLANG.EXE': '/two'};
    final config = XcrossConfig(tools: tools);
    tools.clear();
    expect(config.tool('clang'), '/one');
    expect(config.tool('CLANG.EXE'), '/two');
    expect(config.tool('clang.exe'), isNull);
    expect(config.copyWith().tools, config.tools);
    expect(config.copyWith().toYaml(), config.toYaml());
    expect(() => config.tools['clang'] = '/other', throwsUnsupportedError);
    for (final name in ['', '  ', 'bad\nname', 'bad\u0000name']) {
      expect(
        () => XcrossConfig(tools: {name: '/tool'}),
        throwsA(isA<XcrossConfigException>()),
      );
    }
  });

  test(
    testOn: '!windows',
    'POSIX decoding preserves case and suffixes through YAML roundtrip',
    () {
      final host = LinuxHost();
      final tool = File(p.join(temporary.path, 'tool'))
        ..writeAsStringSync('tool');
      host.fileSystem.makeExecutable(tool.path);
      final config = XcrossConfig.parse(
        'tools:\n  clang: ${tool.path}\n  " CLANG.EXE ": ${tool.path}\n',
        environment: const {},
        host: host,
        policy: const PosixConfigHost(),
      );
      expect(config.tools, {'clang': tool.path, 'CLANG.EXE': tool.path});
      expect(config.tool('clang.exe'), isNull);
      expect(
        XcrossConfig.parse(
          config.copyWith().toYaml(),
          environment: const {},
          host: host,
          policy: const PosixConfigHost(),
        ).tools,
        config.tools,
      );
      expect(
        () => XcrossConfig.parse(
          'tools:\n  clang: ${tool.path}\n  " clang ": ${tool.path}\n',
          environment: const {},
          host: host,
          policy: const PosixConfigHost(),
        ),
        throwsA(
          isA<XcrossConfigException>().having(
            (error) => error.message,
            'message',
            contains('Duplicate tool after host normalization'),
          ),
        ),
      );
    },
  );

  for (final suffix in ['.EXE', '.CMD', '.BAT', '.COM']) {
    test('Windows decoding normalizes mixed case and $suffix on POSIX', () {
      final fixture = AuthNamespaceFixture(style: p.Style.windows);
      addTearDown(fixture.dispose);
      final tool = fixture.path('clang.exe');
      fixture.fileSystem.file(tool).writeAsStringSync('tool');
      final host = WindowsHost(fileSystem: fixture.fileSystem);
      final config = XcrossConfig.parse(
        'tools:\n  " ClAnG$suffix ": $tool\n',
        environment: const {},
        host: host,
        policy: const WindowsConfigHost(),
      );
      expect(config.tools, {'clang': tool});
      expect(config.tool('clang'), tool);
      expect(
        XcrossConfig.parse(
          config.copyWith().toYaml(),
          environment: const {},
          host: host,
          policy: const WindowsConfigHost(),
        ).tools,
        config.tools,
      );
      expect(
        () => XcrossConfig.parse(
          'tools:\n  clang: $tool\n  ClAnG$suffix: $tool\n',
          environment: const {},
          host: host,
          policy: const WindowsConfigHost(),
        ),
        throwsA(
          isA<XcrossConfigException>().having(
            (error) => error.message,
            'message',
            contains('Duplicate tool after host normalization'),
          ),
        ),
      );
    });
  }

  test('serializes canonical YAML and round trips PATH as a list', () {
    final config = XcrossConfig.parse(
      valid,
      environment: const {'HOME': '/home/test'},
      host: LinuxHost(),
      policy: const PosixConfigHost(),
    );
    final yaml = config.toYaml();

    expect(yaml, startsWith('roots:\n  darwinSdk: "/opt/darwin"'));
    expect(yaml, contains('swift: "/opt/swift/bin"'));
    expect(yaml, contains('llvm:\n    - "/opt/llvm/bin"'));
    expect(yaml, contains('setup: "https://example.com/setup.sh"'));
    expect(yaml, contains('excluded_commands:\n  - "config"\n  - "setup"'));
    expect(yaml, contains('PATH:\n    - "/opt/bin"'));
    expect(
      yaml.indexOf('C_INCLUDE_PATH:'),
      lessThan(yaml.indexOf('\n  PATH:')),
    );
    expect(
      XcrossConfig.parse(
        yaml,
        environment: const {},
        host: LinuxHost(),
        policy: const PosixConfigHost(),
      ).toYaml(),
      yaml,
    );
  });

  test(
    testOn: '!windows',

    'store discovers, selects, and atomically saves configuration',
    () async {
      final yaml = File(p.join(temporary.path, 'config.yml'))
        ..writeAsStringSync(valid);
      final store = XcrossConfigStore(
        LinuxHost(environment: const {'HOME': '/home/me'}),
        directory: temporary.path,
        policy: const PosixConfigHost(),
        environment: const {'HOME': '/home/test'},
      );
      expect(store.selectedFile()!.path, yaml.path);
      expect((await store.load())!.roots.flutterSdk, '/home/test/flutter');

      final config = XcrossConfig(
        roots: const XcrossConfigRoots(darwinSdk: '/sdk'),
      );
      final target = await store.save(config);
      expect(target.path, yaml.path);
      expect(target.readAsStringSync(), config.toYaml());
      expect(
        temporary.listSync().where((entity) => entity.path.contains('.tmp-')),
        isEmpty,
      );
    },
  );

  test(
    testOn: '!windows',
    'store defaults to config.yaml when no file is selected',
    () async {
      final store = XcrossConfigStore(
        LinuxHost(environment: const {'HOME': '/home/me'}),
        directory: temporary.path,
        policy: const PosixConfigHost(),
        environment: const {},
      );
      final target = await store.save(XcrossConfig());
      expect(p.basename(target.path), 'config.yaml');
    },
  );

  test(
    'selector for absent file fails and defaults use injected environment',
    () async {
      final store = XcrossConfigStore(
        LinuxHost(environment: const {'HOME': '/home/me'}),
        environment: {'XCROSS_CONFIG': p.join(temporary.path, 'missing.yaml')},
        policy: const PosixConfigHost(),
      );
      await expectLater(store.load(), throwsA(isA<XcrossConfigException>()));
      expect(
        XcrossConfigStore(
          LinuxHost(environment: const {'HOME': '/home/me'}),
          environment: {'HOME': '/home/me'},
          policy: const PosixConfigHost(),
        ).defaultDirectory,
        '/home/me/.config/xcross',
      );
    },
  );
}
