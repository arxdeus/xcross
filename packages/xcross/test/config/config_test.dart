import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/xcross.dart';

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
      windows: false,
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
  });

  test(
    'allows roots and operation-specific roots to be omitted while parsing',
    () {
      expect(
        XcrossConfig.parse(
          '{}',
          environment: const {},
          windows: false,
        ).roots.toMap(),
        isEmpty,
      );
      expect(
        XcrossConfig.parse(
          'roots:\n  flutterSdk: /opt/flutter\n',
          environment: const {},
          windows: false,
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
          () =>
              XcrossConfig.parse(source, environment: const {}, windows: false),
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
        windows: false,
      ),
      '/h/sdk//h/root//j/%APPDATA%',
    );
    expect(
      expandNativeEnvironment(
        r'C:\%USERPROFILE%\$HOME',
        environment: const {'USERPROFILE': r'C:\Users\me'},
        windows: true,
      ),
      r'C:\C:\Users\me\$HOME',
    );
    expect(
      () => expandNativeEnvironment(
        r'$A',
        environment: const {'A': r'$B', 'B': r'$A'},
        windows: false,
      ),
      throwsA(isA<XcrossConfigException>()),
    );
    expect(
      () => expandNativeEnvironment(
        r'$MISSING',
        environment: const {},
        windows: false,
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
        windows: false,
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
    ]) {
      expect(
        () => XcrossConfig.parse(source, environment: const {}, windows: false),
        throwsA(isA<XcrossConfigException>()),
        reason: source,
      );
    }
  });

  test(
    'validate requires absolute roots but permits absent root directories',
    () {
      XcrossConfig(
        roots: const XcrossConfigRoots(flutterSdk: '/missing/flutter'),
      ).validate(windows: false);

      expect(
        () => XcrossConfig(
          roots: const XcrossConfigRoots(flutterSdk: 'relative/flutter'),
        ).validate(windows: false),
        throwsA(isA<XcrossConfigException>()),
      );
    },
  );

  test('accepts scalar llvm and rejects unknown or malformed toolchains', () {
    expect(
      XcrossConfig.parse(
        'toolchains:\n  llvm: /opt/llvm/bin\n',
        environment: const {},
        windows: false,
      ).toolchains.llvm,
      ['/opt/llvm/bin'],
    );
    for (final source in [
      'toolchains:\n  gcc: /opt/gcc/bin\n',
      'toolchains:\n  swift: [/one, /two]\n',
      'toolchains:\n  llvm: 42\n',
    ]) {
      expect(
        () => XcrossConfig.parse(source, environment: const {}, windows: false),
        throwsA(isA<XcrossConfigException>()),
      );
    }
  });

  test('validate requires tools to be regular executable files', () {
    final executable = File(p.join(temporary.path, 'tool'))
      ..writeAsStringSync('#!/bin/sh\n');
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['755', executable.path]);
    }
    XcrossConfig(
      tools: {'tool': executable.path},
    ).validate(windows: Platform.isWindows);

    final plain = File(p.join(temporary.path, 'plain'))
      ..writeAsStringSync('plain');
    expect(
      () => XcrossConfig(tools: {'plain': plain.path}).validate(windows: false),
      throwsA(isA<XcrossConfigException>()),
    );
    expect(
      () => XcrossConfig(
        tools: {'missing': p.join(temporary.path, 'missing')},
      ).validate(),
      throwsA(isA<XcrossConfigException>()),
    );
  });

  test('normalizes tool names and rejects collisions', () {
    final tool = File(p.join(temporary.path, 'clang'))
      ..writeAsStringSync('tool');
    if (!Platform.isWindows) Process.runSync('chmod', ['755', tool.path]);
    final source = 'tools:\n  CLANG.EXE: ${tool.path}\n';
    final config = XcrossConfig.parse(
      source,
      environment: const {},
      windows: false,
    );
    expect(config.tool('clang'), tool.path);
    expect(config.tool('CLANG.EXE'), tool.path);
    expect(
      () => XcrossConfig.parse(
        'tools:\n  clang: /one\n  clang.exe: /two\n',
        environment: const {},
        windows: false,
      ),
      throwsA(isA<XcrossConfigException>()),
    );
  });

  test('serializes canonical YAML and round trips PATH as a list', () {
    final config = XcrossConfig.parse(
      valid,
      environment: const {'HOME': '/home/test'},
      windows: false,
    );
    final yaml = config.toYaml();

    expect(yaml, startsWith('roots:\n  darwinSdk: "/opt/darwin"'));
    expect(yaml, contains('swift: "/opt/swift/bin"'));
    expect(yaml, contains('llvm:\n    - "/opt/llvm/bin"'));
    expect(yaml, contains('PATH:\n    - "/opt/bin"'));
    expect(
      yaml.indexOf('C_INCLUDE_PATH:'),
      lessThan(yaml.indexOf('\n  PATH:')),
    );
    expect(
      XcrossConfig.parse(yaml, environment: const {}, windows: false).toYaml(),
      yaml,
    );
  });

  test(
    'store discovers, selects, and atomically saves configuration',
    () async {
      final yaml = File(p.join(temporary.path, 'config.yml'))
        ..writeAsStringSync(valid);
      final store = XcrossConfigStore(
        directory: temporary.path,
        environment: const {'HOME': '/home/test'},
        windows: false,
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

  test('store defaults to config.yaml when no file is selected', () async {
    final store = XcrossConfigStore(
      directory: temporary.path,
      environment: const {},
      windows: false,
    );
    final target = await store.save(XcrossConfig());
    expect(p.basename(target.path), 'config.yaml');
  });

  test(
    'selector for absent file fails and defaults use injected environment',
    () async {
      final store = XcrossConfigStore(
        environment: {'XCROSS_CONFIG': p.join(temporary.path, 'missing.yaml')},
        windows: false,
      );
      await expectLater(store.load(), throwsA(isA<XcrossConfigException>()));
      expect(
        const XcrossConfigStore(
          environment: {'HOME': '/home/me'},
          windows: false,
        ).defaultDirectory,
        '/home/me/.config/xcross',
      );
    },
  );
}
