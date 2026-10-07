import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/linux/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_compiler.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/tool/tool_alias_operation.dart';

import 'swiftpm_test_context.dart';

final _runtime = testSwiftPmRuntime();

void main() {
  late Directory root;
  late String compiler;
  late List<List<String>> calls;
  late SwiftPmManifestCompiler manifestCompiler;
  late List<String> log;

  setUp(() {
    root = Directory.systemTemp.createTempSync('xcross-manifest-compiler-');
    compiler = p.join(root.path, 'swiftc');
    File(compiler).writeAsStringSync('compiler');
    calls = [];
    log = [];
    manifestCompiler = SwiftPmManifestCompiler(
      fileSystem: _runtime.artifactFileSystem,
      policy: _runtime.checkoutManifestNormalizer.policy,
      sourceNormalizer: _runtime.sourceNormalizer,
      log: log.add,
      run: (executable, arguments) async {
        calls.add([executable, ...arguments]);
        final output = arguments.indexOf('-o');
        if (output >= 0) {
          File(arguments[output + 1]).writeAsStringSync(
            'binary:${File(_contents(arguments)).readAsStringSync()}',
          );
        }
        return 0;
      },
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  SwiftPmManifestCompilerConfiguration configuration({
    String policy = 'a',
    Map<String, List<String>> consumedProducts = const {},
  }) => SwiftPmManifestCompilerConfiguration(
    compiler: compiler,
    cacheRoot: p.join(root.path, 'cache'),
    policy: policy,
    consumedProducts: consumedProducts,
  );

  List<String> invocation(
    String manifest, {
    required String temp,
    String manifestPath = '/Package.swift',
    List<String> extra = const [],
    String output = 'root-manifest',
  }) {
    final directory = Directory(p.join(root.path, temp))..createSync();
    final contents = p.join(directory.path, 'manifest.swift');
    File(contents).writeAsStringSync(manifest);
    final overlay = p.join(directory.path, 'vfs.yaml');
    File(overlay).writeAsStringSync(
      jsonEncode({
        'version': 0,
        'roots': [
          {'name': manifestPath, 'external-contents': contents, 'type': 'file'},
        ],
        'use-external-names': false,
      }),
    );
    return [
      '-vfsoverlay',
      overlay,
      '-swift-version',
      '5',
      manifestPath,
      ...extra,
      '-o',
      p.join(directory.path, output),
    ];
  }

  test('forwards a compiler call without an overlay unchanged', () async {
    final code = await manifestCompiler.compile([
      '-scan-dependencies',
      'Package.swift',
    ], configuration());
    expect(code, 0);
    expect(calls, [
      [compiler, '-scan-dependencies', 'Package.swift'],
    ]);
  });

  test('compiles the host manifest policy into the temporary copy', () async {
    const manifest = 'let flags = ["-Wl,-rpath,@loader_path"]\n';
    final arguments = invocation(manifest, temp: 'one');
    expect(await manifestCompiler.compile(arguments, configuration()), 0);
    final patched = File(_contents(arguments)).readAsStringSync();
    expect(patched, contains('"-Xlinker", "-rpath"'));
    expect(calls.single.sublist(1), arguments);
  });

  test('reuses a compiled manifest across temporary directories', () async {
    const manifest = 'let package = 1\n';
    final first = invocation(manifest, temp: 'one');
    final second = invocation(manifest, temp: 'two');
    expect(await manifestCompiler.compile(first, configuration()), 0);
    expect(await manifestCompiler.compile(second, configuration()), 0);
    expect(calls, hasLength(1));
    expect(
      File(second.last).readAsStringSync(),
      File(first.last).readAsStringSync(),
    );
    expect(log.where((line) => line.startsWith('hit ')), hasLength(1));
  });

  test('recompiles when the policy digest changes', () async {
    const manifest = 'let package = 1\n';
    await manifestCompiler.compile(
      invocation(manifest, temp: 'one'),
      configuration(),
    );
    await manifestCompiler.compile(
      invocation(manifest, temp: 'two'),
      configuration(policy: 'b'),
    );
    expect(calls, hasLength(2));
  });

  test('recompiles when the compiler arguments change', () async {
    const manifest = 'let package = 1\n';
    await manifestCompiler.compile(
      invocation(manifest, temp: 'one'),
      configuration(),
    );
    await manifestCompiler.compile(
      invocation(manifest, temp: 'two', extra: ['-DOTHER']),
      configuration(),
    );
    expect(calls, hasLength(2));
  });

  test('keys location-sensitive manifests on their path', () async {
    const manifest = 'let here = #filePath\n';
    await manifestCompiler.compile(
      invocation(manifest, temp: 'one', manifestPath: '/a/Package.swift'),
      configuration(),
    );
    await manifestCompiler.compile(
      invocation(manifest, temp: 'two', manifestPath: '/b/Package.swift'),
      configuration(),
    );
    expect(calls, hasLength(2));
  });

  test('never caches a call that serializes diagnostics', () async {
    const manifest = 'let package = 1\n';
    for (final temp in ['one', 'two']) {
      await manifestCompiler.compile(
        invocation(
          manifest,
          temp: temp,
          extra: ['-Xfrontend', '-serialize-diagnostics-path'],
        ),
        configuration(),
      );
    }
    expect(calls, hasLength(2));
  });

  test('does not publish a failed compilation', () async {
    final failing = SwiftPmManifestCompiler(
      fileSystem: _runtime.artifactFileSystem,
      policy: _runtime.checkoutManifestNormalizer.policy,
      sourceNormalizer: _runtime.sourceNormalizer,
      run: (executable, arguments) async {
        calls.add(arguments);
        return 3;
      },
    );
    const manifest = 'let package = 1\n';
    expect(
      await failing.compile(invocation(manifest, temp: 'one'), configuration()),
      3,
    );
    expect(
      await failing.compile(invocation(manifest, temp: 'two'), configuration()),
      3,
    );
    expect(calls, hasLength(2));
  });

  test('removes missing resources only for on-disk packages', () async {
    final package = Directory(p.join(root.path, 'package'))..createSync();
    File(p.join(package.path, 'Package.swift')).writeAsStringSync('');
    const manifest =
        'let package = Package(targets: [.target(name: "A", '
        'resources: [.process("Missing")])])\n';
    final local = invocation(
      manifest,
      temp: 'one',
      manifestPath: p.join(package.path, 'Package.swift'),
    );
    final remote = invocation(manifest, temp: 'two');
    await manifestCompiler.compile(local, configuration());
    await manifestCompiler.compile(remote, configuration());
    expect(
      File(_contents(local)).readAsStringSync(),
      isNot(contains('Missing')),
    );
    expect(File(_contents(remote)).readAsStringSync(), contains('Missing'));
  });

  test('installs a stable POSIX manifest compiler script', () async {
    final directory = p.join(root.path, 'bin');
    Future<String> install() =>
        const LinuxSwiftPmHostPolicy().installManifestCompiler(
          _runtime.host,
          directory: directory,
          executable: '/opt/xcross bin/xcross',
          configuration: '{"policy":"a"}',
        );
    final shim = await install();
    final modified = File(shim).lastModifiedSync();
    expect(await install(), shim);
    expect(File(shim).lastModifiedSync(), modified);
    expect(p.basename(shim), manifestCompilerName);
    final script = File(shim).readAsStringSync();
    expect(script, contains("$manifestCompilerVariable='$shim.policy.json'"));
    expect(script, contains("exec '/opt/xcross bin/xcross' \"\$@\""));
    expect(File('$shim.policy.json').readAsStringSync(), '{"policy":"a"}');
  });

  test('exposes one stable manifest compiler to every swift process', () async {
    final bin = Directory(p.join(root.path, 'toolchain'))..createSync();
    for (final tool in ['swift', 'swiftc']) {
      File(p.join(bin.path, tool)).writeAsStringSync('tool');
      _runtime.host.fileSystem.makeExecutable(p.join(bin.path, tool));
    }
    final xcross = p.join(root.path, 'xcross');
    File(xcross).writeAsStringSync('xcross');
    final cache = p.join(root.path, 'cache');
    final environment = {
      ...Platform.environment,
      'PATH': bin.path,
      'XCROSS_CACHE_DIR': cache,
    };
    Future<Map<String, String>> resolve() {
      final runtime = testSwiftPmRuntime(environment: environment);
      return SwiftPmProcessPolicy(
        host: runtime.host,
        hostPolicy: runtime.hostPolicy,
        runner: runtime.runner,
        tools: AppleToolShimResolver(
          runtime.target,
          runtime.runner,
          runtime.sdkRepository,
          runtime.toolchainResolver,
          hostTools: MacOSNativeHostTools(runtime.host, runtime.runner),
          executable: xcross,
        ),
      ).swiftProcessEnvironment();
    }

    final first = await resolve();
    final second = await resolve();
    final shim = first['SWIFT_EXEC_MANIFEST']!;
    expect(second, first);
    expect(p.isWithin(p.join(cache, 'manifest-compiler'), shim), isTrue);
    expect(first[manifestPolicyVariable], isNotEmpty);
    final configuration = SwiftPmManifestCompilerConfiguration.fromJson(
      jsonDecode(File('$shim.policy.json').readAsStringSync())
          as Map<String, Object?>,
    );
    expect(configuration.compiler, p.join(bin.path, 'swiftc'));
    expect(configuration.policy, first[manifestPolicyVariable]);

    final runtime = testSwiftPmRuntime(environment: environment);
    final consumed =
        await SwiftPmProcessPolicy(
          host: runtime.host,
          hostPolicy: runtime.hostPolicy,
          runner: runtime.runner,
          tools: AppleToolShimResolver(
            runtime.target,
            runtime.runner,
            runtime.sdkRepository,
            runtime.toolchainResolver,
            hostTools: MacOSNativeHostTools(runtime.host, runtime.runner),
            executable: xcross,
          ),
        ).swiftProcessEnvironment(
          consumedProducts: {
            'dependency': {'Product'},
          },
        );
    expect(
      consumed[manifestPolicyVariable],
      isNot(first[manifestPolicyVariable]),
    );
    expect(
      SwiftPmManifestCompilerConfiguration.fromJson(
        jsonDecode(
              File(
                '${consumed['SWIFT_EXEC_MANIFEST']!}.policy.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>,
      ).consumedProducts,
      {
        'dependency': ['Product'],
      },
    );

    File(xcross).writeAsStringSync('updated xcross');
    final updated = await resolve();
    expect(
      updated[manifestPolicyVariable],
      isNot(first[manifestPolicyVariable]),
    );
    expect(updated['SWIFT_EXEC_MANIFEST'], isNot(shim));
  });

  test('derives the package identity from the manifest output name', () {
    expect(
      SwiftPmManifestCompiler.manifestIdentity('/tmp/Dependency-manifest'),
      'dependency',
    );
    expect(
      SwiftPmManifestCompiler.manifestIdentity(
        r'C:\tmp\dependency-manifest.exe',
      ),
      'dependency',
    );
    expect(SwiftPmManifestCompiler.manifestIdentity('/tmp/other'), isNull);
  });

  test(
    'aliases products the build consumes from the manifest identity',
    () async {
      const manifest = '''
var products: [Product] = [
    .library(name: "PublicSDK", targets: ["BinaryArtifact"]),
]
var targets: [Target] = [
    .binaryTarget(name: "BinaryArtifact", url: "SDK.zip", checksum: "abc"),
]
if getenv("CROSS_HOST_SOURCE") != nil {
    products.removeAll()
    targets.removeAll()
    products.append(.library(name: "SourceProduct", targets: ["SourceImpl"]))
    targets.append(.target(name: "SourceImpl", path: "Sources"))
}
''';
      final consumed = configuration(
        consumedProducts: {
          'dependency': ['PublicSDK'],
        },
      );
      final other = invocation(
        manifest,
        temp: 'other',
        output: 'other-manifest',
      );
      await manifestCompiler.compile(other, consumed);
      expect(File(_contents(other)).readAsStringSync(), manifest);
      final arguments = invocation(
        manifest,
        temp: 'dependency',
        output: 'dependency-manifest',
      );
      await manifestCompiler.compile(arguments, consumed);
      expect(
        File(_contents(arguments)).readAsStringSync(),
        contains('.library(name: "PublicSDK", targets: ["SourceImpl"])'),
      );
    },
  );

  test('keys the manifest policy on consumed products', () {
    expect(manifestCompilerEnvironmentDigest('policy', const {}), 'policy');
    final first = manifestCompilerEnvironmentDigest('policy', const {
      'dependency': ['First'],
    });
    expect(first, isNot('policy'));
    expect(
      manifestCompilerEnvironmentDigest('policy', const {
        'dependency': ['Second'],
      }),
      isNot(first),
    );
  });

  test('runs an overlay scan without an output uncached', () async {
    final arguments = invocation(
      'let package = 1\n',
      temp: 'one',
    ).takeWhile((argument) => argument != '-o').toList();
    for (var repetition = 0; repetition < 2; repetition++) {
      expect(await manifestCompiler.compile(arguments, configuration()), 0);
    }
    expect(calls, [
      [compiler, ...arguments],
      [compiler, ...arguments],
    ]);
    expect(Directory(p.join(root.path, 'cache')).existsSync(), isFalse);
  });

  test('chains to a manifest compiler the user configured', () async {
    final bin = Directory(p.join(root.path, 'toolchain'))..createSync();
    File(p.join(bin.path, 'swift')).writeAsStringSync('tool');
    _runtime.host.fileSystem.makeExecutable(p.join(bin.path, 'swift'));
    final custom = p.join(root.path, 'custom-swiftc');
    File(custom).writeAsStringSync('custom');
    final xcross = p.join(root.path, 'xcross');
    File(xcross).writeAsStringSync('xcross');
    final runtime = testSwiftPmRuntime(
      environment: {
        ...Platform.environment,
        'PATH': bin.path,
        'XCROSS_CACHE_DIR': p.join(root.path, 'cache'),
        'SWIFT_EXEC_MANIFEST': custom,
      },
    );
    final environment = await SwiftPmProcessPolicy(
      host: runtime.host,
      hostPolicy: runtime.hostPolicy,
      runner: runtime.runner,
      tools: AppleToolShimResolver(
        runtime.target,
        runtime.runner,
        runtime.sdkRepository,
        runtime.toolchainResolver,
        hostTools: MacOSNativeHostTools(runtime.host, runtime.runner),
        executable: xcross,
      ),
    ).swiftProcessEnvironment();
    final shim = environment['SWIFT_EXEC_MANIFEST']!;
    expect(shim, isNot(custom));
    final configuration = SwiftPmManifestCompilerConfiguration.fromJson(
      jsonDecode(File('$shim.policy.json').readAsStringSync())
          as Map<String, Object?>,
    );
    expect(configuration.compiler, custom);
  });

  test('dispatches the manifest compiler through the tool alias', () async {
    final sidecar = p.join(root.path, 'policy.json');
    File(sidecar).writeAsStringSync(jsonEncode(configuration().toJson()));
    final aliases = ToolAliasOperation(
      _runtime.runner,
      manifestCompiler: (run, {log}) => SwiftPmManifestCompiler(
        fileSystem: _runtime.artifactFileSystem,
        policy: _runtime.checkoutManifestNormalizer.policy,
        sourceNormalizer: _runtime.sourceNormalizer,
        run: run,
      ),
    );
    Future<int> forward(String executable, List<String> arguments) async {
      calls.add([executable, ...arguments]);
      return 5;
    }

    expect(
      await aliases.run(
        ['-version'],
        executablePath: p.join(root.path, 'xcross'),
        environment: {manifestCompilerVariable: sidecar},
        run: forward,
      ),
      5,
    );
    expect(
      await aliases.run(
        ['-version'],
        executablePath: p.join(root.path, 'xcross'),
        environment: const {},
        run: forward,
      ),
      isNull,
    );
    final alias = p.join(root.path, '$manifestCompilerName.exe');
    File(
      '$alias.policy.json',
    ).writeAsStringSync(jsonEncode(configuration().toJson()));
    expect(
      await aliases.run(
        ['-version'],
        executablePath: alias,
        environment: const {},
        run: forward,
      ),
      5,
    );
    expect(calls, [
      [compiler, '-version'],
      [compiler, '-version'],
    ]);
  });
}

String _contents(List<String> arguments) {
  final overlay =
      jsonDecode(File(arguments[1]).readAsStringSync()) as Map<String, Object?>;
  final roots = overlay['roots']! as List<Object?>;
  return (roots.single! as Map<String, Object?>)['external-contents']!
      as String;
}
