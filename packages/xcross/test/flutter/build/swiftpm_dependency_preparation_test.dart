import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';

import 'support/checkout_test_context.dart';
import 'support/dependency_preparation_test_context.dart';

void main() {
  late Directory root;
  late CheckoutTestContext context;
  setUp(() {
    root = Directory.systemTemp.createTempSync(
      'xcross-dependency-preparation-',
    );
    context = CheckoutTestContext(root, (_) => CheckoutTestProcess());
  });
  tearDown(() async {
    await context.output.close();
    root.deleteSync(recursive: true);
  });

  SwiftPmDependencyCommand command({
    String triple = 'arm64-apple-ios',
    Map<String, String>? environment,
  }) => SwiftPmDependencyCommand(
    swift: '/fixture/swift-package',
    pluginsDir: p.join(root.path, 'plugins'),
    scratchPath: p.join(root.path, 'scratch'),
    swiftSdksPath: p.join(root.path, 'sdks'),
    toolsetPath: p.join(root.path, 'toolset.json'),
    vendorDir: p.join(root.path, 'vendor'),
    binaryArtifactStore: p.join(root.path, 'store'),
    binaryArtifactFallback: p.join(root.path, 'fallback'),
    swiftPmArtifactJunctionCapability: false,
    packageLocalArtifactJunctionCapability: false,
    environment: environment,
    swiftSdkTriple: triple,
  );

  test(
    'commands defensively freeze environment, directory and dependency collections',
    () {
      final environment = {'DEPENDENCY_TOKEN': 'before'};
      final prepare = command(environment: environment);
      environment['DEPENDENCY_TOKEN'] = 'after';
      expect(prepare.environment, {'DEPENDENCY_TOKEN': 'before'});
      expect(
        () => prepare.environment!['extra'] = 'value',
        throwsUnsupportedError,
      );
      final directories = ['before'];
      final pinned = SwiftPmPinnedDependencyCommand(
        packageDirectories: directories,
        vendorDir: root.path,
      );
      directories.add('after');
      expect(pinned.packageDirectories, ['before']);
      expect(
        () => pinned.packageDirectories.add('extra'),
        throwsUnsupportedError,
      );
      final dependencies = <SwiftPmPackageDependency>[];
      final state = SwiftPmBinaryAttemptState();
      final artifacts = SwiftPmDependencyArtifactCommand(
        packageRoot: root.path,
        scratchPath: root.path,
        store: root.path,
        fallback: root.path,
        dependencies: dependencies,
        state: state,
        capability: false,
      );
      expect(artifacts.dependencies, isEmpty);
      expect(identical(artifacts.dependencies, dependencies), isFalse);
      expect(artifacts.dependencies.clear, throwsUnsupportedError);
      expect(identical(artifacts.state, state), isTrue);
      expect(command().environment, isNull);
    },
  );

  for (final triple in ['arm64-apple-ios', 'arm64-apple-ios-simulator']) {
    test(
      'selected Windows prepare preserves complete leading manifest argv for $triple',
      () async {
        final policy = RecordingDependencyManifestPolicy();
        final cloner = RecordingDependencyCloner();
        final preparation = dependencyTestPreparation(
          context,
          root,
          manifestPolicy: policy,
          cloner: cloner,
        );
        final environment = {'DEPENDENCY_TOKEN': 'before'};
        final data = command(triple: triple, environment: environment);
        environment['DEPENDENCY_TOKEN'] = 'after';
        await preparation.prepare(data);
        expect(context.processes.commands, hasLength(1));
        final invocation = context.processes.commands.single;
        expect(invocation.executable, '/fixture/swift-package');
        expect(invocation.arguments, [
          '-Xmanifest',
          '-Xfrontend',
          '-Xmanifest',
          '-import-module',
          '-Xmanifest',
          '-Xfrontend',
          '-Xmanifest',
          'CRT',
          '--package-path',
          data.pluginsDir,
          '--scratch-path',
          data.scratchPath,
          '--swift-sdks-path',
          data.swiftSdksPath,
          '--swift-sdk',
          triple,
          '--toolset',
          data.toolsetPath,
          'resolve',
        ]);
        expect(invocation.arguments, isNot(contains('package')));
        expect(invocation.environment?['DEPENDENCY_TOKEN'], 'before');
        expect(policy.calls, isEmpty);
        expect(cloner.calls, isEmpty);
      },
    );
  }

  test(
    'Windows owns resolved normalization and reruns resolve only after actual change',
    () async {
      final data = command();
      final checkout = Directory(
        p.join(data.scratchPath, 'checkouts', 'dependency'),
      )..createSync(recursive: true);
      final manifest = File(p.join(checkout.path, 'Package.swift'))
        ..writeAsStringSync('fixtureOld');
      final policy = RecordingDependencyManifestPolicy();
      final preparation = dependencyTestPreparation(
        context,
        root,
        manifestPolicy: policy,
        cloner: RecordingDependencyCloner(),
      );
      await preparation.prepare(data);
      expect(manifest.readAsStringSync(), 'fixtureNew');
      expect(policy.calls.single.directory, checkout.path);
      expect(policy.calls.single.products, isEmpty);
      expect(
        context.processes.commands.where(
          (call) => call.executable == data.swift,
        ),
        hasLength(2),
      );
      final count = context.processes.commands
          .where((call) => call.executable == data.swift)
          .length;
      await preparation.prepare(data);
      expect(
        context.processes.commands.where(
          (call) => call.executable == data.swift,
        ),
        hasLength(count + 1),
      );
    },
  );

  test(
    'failed resolve with no recoverable artifacts leaves manifests intact and does not retry',
    () async {
      await context.output.close();
      context = CheckoutTestContext(
        root,
        (_) => CheckoutTestProcess(
          code: 1,
          error: utf8.encode('invalid package manifest'),
        ),
      );
      final data = command();
      final checkout = Directory(
        p.join(data.scratchPath, 'checkouts', 'dependency'),
      )..createSync(recursive: true);
      final manifest = File(p.join(checkout.path, 'Package.swift'))
        ..writeAsStringSync('fixtureOld');
      final policy = RecordingDependencyManifestPolicy();
      final preparation = dependencyTestPreparation(
        context,
        root,
        manifestPolicy: policy,
        cloner: RecordingDependencyCloner(),
      );
      await expectLater(preparation.prepare(data), throwsA(isA<Object>()));
      expect(context.processes.commands, hasLength(1));
      expect(policy.calls, isEmpty);
      expect(manifest.readAsStringSync(), 'fixtureOld');
    },
  );

  const pinnedManifest = '''
let package = Package(name: "Plugin", dependencies: [
.package(url: "https://example.invalid/dep.git", exact: "1.2.3")
], targets: [.target(name: "Plugin", dependencies: [
.product(name: "DepProduct", package: "dep")
])])
''';

  test(
    'pinned bootstrap clones through constructor port and normalizes before manifest rewrite',
    () async {
      final plugin = Directory(p.join(root.path, 'plugin'))..createSync();
      final manifest = File(p.join(plugin.path, 'Package.swift'))
        ..writeAsStringSync(pinnedManifest);
      final policy = RecordingDependencyManifestPolicy();
      final cloner = RecordingDependencyCloner();
      final preparation = dependencyTestPreparation(
        context,
        root,
        manifestPolicy: policy,
        cloner: cloner,
      );
      final result = await preparation.bootstrapPinned(
        SwiftPmPinnedDependencyCommand(
          packageDirectories: [plugin.path],
          vendorDir: p.join(root.path, 'vendor'),
        ),
      );
      expect(result.pins, {'https://example.invalid/dep': '1.2.3'});
      expect(result.originals, {manifest.path: pinnedManifest});
      expect(cloner.calls, hasLength(1));
      final clone = cloner.calls.single;
      expect(
        (clone.git, clone.url, clone.ref),
        ('/fixture/git', 'https://example.invalid/dep.git', '1.2.3'),
      );
      expect(
        File(p.join(clone.destination, 'Package.swift')).readAsStringSync(),
        'fixtureNew',
      );
      expect(policy.calls.single.products, {'DepProduct'});
      expect(
        manifest.readAsStringSync(),
        contains('path: "${clone.destination}"'),
      );
      expect(context.processes.commands, isEmpty);
    },
  );

  test(
    'version range for same identity leaves solver ownership and performs no clone',
    () async {
      final plugin = Directory(p.join(root.path, 'plugin'))..createSync();
      const original =
          '$pinnedManifest\n.package(url: "https://example.invalid/dep", from: "1.0.0")';
      final manifest = File(p.join(plugin.path, 'Package.swift'))
        ..writeAsStringSync(original);
      final cloner = RecordingDependencyCloner();
      final preparation = dependencyTestPreparation(
        context,
        root,
        manifestPolicy: RecordingDependencyManifestPolicy(),
        cloner: cloner,
      );
      final result = await preparation.bootstrapPinned(
        SwiftPmPinnedDependencyCommand(
          packageDirectories: [plugin.path],
          vendorDir: p.join(root.path, 'vendor'),
        ),
      );
      expect(result.pins, isEmpty);
      expect(result.originals, isEmpty);
      expect(cloner.calls, isEmpty);
      expect(manifest.readAsStringSync(), original);
    },
  );

  test(
    'conflicting pinned revisions fail before cloning or plugin edits',
    () async {
      final plugin = Directory(p.join(root.path, 'plugin'))..createSync();
      const original =
          '$pinnedManifest\n.package(url: "https://example.invalid/dep", revision: "other")';
      final manifest = File(p.join(plugin.path, 'Package.swift'))
        ..writeAsStringSync(original);
      final cloner = RecordingDependencyCloner();
      final preparation = dependencyTestPreparation(
        context,
        root,
        manifestPolicy: RecordingDependencyManifestPolicy(),
        cloner: cloner,
      );
      await expectLater(
        preparation.bootstrapPinned(
          SwiftPmPinnedDependencyCommand(
            packageDirectories: [plugin.path],
            vendorDir: p.join(root.path, 'vendor'),
          ),
        ),
        throwsA(isA<FlutterBuildError>()),
      );
      expect(cloner.calls, isEmpty);
      expect(manifest.readAsStringSync(), original);
    },
  );

  test(
    'failed clone normalization never rewrites original plugin manifest',
    () async {
      final plugin = Directory(p.join(root.path, 'plugin'))..createSync();
      final manifest = File(p.join(plugin.path, 'Package.swift'))
        ..writeAsStringSync(pinnedManifest);
      final cloner = RecordingDependencyCloner();
      final preparation = dependencyTestPreparation(
        context,
        root,
        manifestPolicy: RecordingDependencyManifestPolicy(
          failNormalization: true,
        ),
        cloner: cloner,
      );
      await expectLater(
        preparation.bootstrapPinned(
          SwiftPmPinnedDependencyCommand(
            packageDirectories: [plugin.path],
            vendorDir: p.join(root.path, 'vendor'),
          ),
        ),
        throwsStateError,
      );
      expect(cloner.calls, hasLength(1));
      expect(manifest.readAsStringSync(), pinnedManifest);
    },
  );

  test(
    'selected recovery reports owned normalization without attempting absent archives',
    () async {
      final scratch = p.join(root.path, 'scratch');
      final checkout = Directory(p.join(scratch, 'checkouts', 'dependency'))
        ..createSync(recursive: true);
      final manifest = File(p.join(checkout.path, 'Package.swift'))
        ..writeAsStringSync('fixtureOld');
      final preparation = dependencyTestPreparation(
        context,
        root,
        manifestPolicy: RecordingDependencyManifestPolicy(),
        cloner: RecordingDependencyCloner(),
      );
      final changed = await preparation.recoverArtifacts(
        SwiftPmDependencyArtifactCommand(
          packageRoot: p.join(root.path, 'plugin'),
          scratchPath: scratch,
          store: p.join(root.path, 'store'),
          fallback: p.join(root.path, 'fallback'),
          dependencies: const [],
          state: SwiftPmBinaryAttemptState(),
          capability: false,
        ),
      );
      expect(changed, isTrue);
      expect(manifest.readAsStringSync(), 'fixtureNew');
      expect(context.processes.commands, isEmpty);
    },
  );

  test(
    'Windows clone materialization uses constructor checkout and vendor stamp path',
    () async {
      final clone = Directory(p.join(root.path, 'clone'))..createSync();
      final vendor = p.join(root.path, 'vendor');
      final preparation = dependencyTestPreparation(
        context,
        root,
        manifestPolicy: RecordingDependencyManifestPolicy(),
        cloner: RecordingDependencyCloner(),
      );
      await preparation.materializeClone(clone.path, '/fixture/git', vendor);
      expect(context.processes.commands.single.arguments, [
        '-C',
        clone.path,
        'ls-files',
        '-s',
        '-z',
      ]);
      expect(context.processes.commands.single.executable, '/fixture/git');
      final stamps = Directory(p.join(vendor, '.xcross-symlinks'));
      expect(stamps.existsSync(), isTrue);
      expect(stamps.listSync().whereType<File>(), hasLength(1));
    },
  );

  test(
    'Windows artifact preparation preserves ordinary package with injected rejecting transport',
    () async {
      final package = Directory(p.join(root.path, 'package'))..createSync();
      final manifest = File(p.join(package.path, 'Package.swift'))
        ..writeAsStringSync('let package = Package(name: "Ordinary")');
      final original = manifest.readAsStringSync();
      final preparation = dependencyTestPreparation(
        context,
        root,
        manifestPolicy: RecordingDependencyManifestPolicy(),
        cloner: RecordingDependencyCloner(),
      );
      await preparation.prepareArtifacts(
        package.path,
        p.join(root.path, 'store'),
        p.join(root.path, 'fallback'),
        capability: false,
      );
      expect(manifest.readAsStringSync(), original);
      expect(context.processes.commands, isEmpty);
    },
  );

  test(
    'POSIX preparation retains native implicit behavior without effect collaborators',
    () async {
      const preparation = PosixSwiftPmDependencyPreparation<MacOSHost>();
      await preparation.prepare(command());
      await preparation.materializeClone(root.path, '/fixture/git', root.path);
      await preparation.prepareArtifacts(
        root.path,
        root.path,
        root.path,
        capability: false,
      );
      final pins = await preparation.bootstrapPinned(
        SwiftPmPinnedDependencyCommand(
          packageDirectories: [root.path],
          vendorDir: root.path,
        ),
      );
      expect(pins.pins, isEmpty);
      expect(pins.originals, isEmpty);
      expect(
        await preparation.recoverArtifacts(
          SwiftPmDependencyArtifactCommand(
            packageRoot: root.path,
            scratchPath: root.path,
            store: root.path,
            fallback: root.path,
            dependencies: const [],
            state: SwiftPmBinaryAttemptState(),
            capability: false,
          ),
        ),
        isFalse,
      );
      expect(context.processes.commands, isEmpty);
    },
  );
}
