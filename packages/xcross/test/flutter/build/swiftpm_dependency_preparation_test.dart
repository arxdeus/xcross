import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/network_retry.dart';

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
      expect(command().environment, isNull);
    },
  );

  for (final triple in ['arm64-apple-ios', 'arm64-apple-ios-simulator']) {
    test(
      testOn: '!windows',

      'selected Windows prepare preserves complete leading manifest argv for $triple',
      () async {
        final preparation = dependencyTestPreparation(context, root);
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
      },
    );
  }

  test(
    testOn: '!windows',

    'Windows resolves once and never rewrites resolved checkout manifests',
    () async {
      final data = command();
      final checkout = Directory(
        p.join(data.scratchPath, 'checkouts', 'dependency'),
      )..createSync(recursive: true);
      final manifest = File(p.join(checkout.path, 'Package.swift'))
        ..writeAsStringSync('fixtureOld');
      final preparation = dependencyTestPreparation(context, root);
      await preparation.prepare(data);
      await preparation.prepare(data);
      expect(manifest.readAsStringSync(), 'fixtureOld');
      expect(
        context.processes.commands.where(
          (call) => call.executable == data.swift,
        ),
        hasLength(2),
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
      final preparation = dependencyTestPreparation(context, root);
      await expectLater(preparation.prepare(data), throwsA(isA<Object>()));
      expect(context.processes.commands, hasLength(1));
      expect(manifest.readAsStringSync(), 'fixtureOld');
    },
  );

  test(
    testOn: '!windows',

    'Windows retries a resolve that crashed with an access violation',
    () async {
      await context.output.close();
      var resolves = 0;
      context = CheckoutTestContext(
        root,
        (_) => ++resolves == 1
            ? CheckoutTestProcess(
                code: 1,
                error: utf8.encode('0xC0000005 STATUS_ACCESS_VIOLATION'),
              )
            : CheckoutTestProcess(),
      );
      await dependencyTestPreparation(context, root).prepare(command());
      expect(resolves, 2);
    },
  );

  test(
    'POSIX preparation resolves natively with the command environment',
    () async {
      final preparation = PosixSwiftPmDependencyPreparation<MacOSHost>(
        runner: context.runner,
        processPolicy: dependencyTestProcessPolicy(context, root),
        networkRetry: SwiftPmNetworkRetry(runner: context.runner),
      );
      final data = command(environment: {'DEPENDENCY_TOKEN': 'value'});
      await preparation.prepare(data);
      final invocation = context.processes.commands.single;
      expect(invocation.executable, data.swift);
      expect(invocation.arguments, [
        'package',
        '--package-path',
        data.pluginsDir,
        '--scratch-path',
        data.scratchPath,
        '--swift-sdks-path',
        data.swiftSdksPath,
        '--swift-sdk',
        data.swiftSdkTriple,
        '--toolset',
        data.toolsetPath,
        'resolve',
      ]);
      expect(invocation.environment?['DEPENDENCY_TOKEN'], 'value');
    },
  );

  test(
    testOn: '!windows',

    'Windows re-resolves only when checkout materialization changed',
    () async {
      await context.output.close();
      context = CheckoutTestContext(root, (command) {
        if (command.arguments.contains('ls-files')) {
          return CheckoutTestProcess(
            output: utf8.encode('120000 aa 0\tlink\u0000'),
          );
        }
        if (command.arguments.contains('cat-file')) {
          return CheckoutTestProcess(
            output: utf8.encode('aa blob 7\npayload\n'),
          );
        }
        return CheckoutTestProcess();
      });
      final data = command();
      final checkout = Directory(
        p.join(data.scratchPath, 'checkouts', 'dependency'),
      )..createSync(recursive: true);
      File(p.join(checkout.path, '.git', 'HEAD'))
        ..createSync(recursive: true)
        ..writeAsStringSync('identity');
      File(p.join(checkout.path, 'payload')).writeAsStringSync('actual');
      File(p.join(checkout.path, 'link')).writeAsStringSync('payload');
      final preparation = dependencyTestPreparation(context, root);
      int resolves() => context.processes.commands
          .where((call) => call.executable == data.swift)
          .length;
      await preparation.prepare(data);
      expect(resolves(), 2);
      await preparation.prepare(data);
      expect(resolves(), 3);
    },
  );
}
