import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/checkout_link_creator.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/checkout_link_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';

import 'support/checkout_test_context.dart';

void main() {
  late Directory root;
  late CheckoutTestContext context;
  setUp(() {
    root = Directory.systemTemp.createTempSync('xcross-checkout-policy-');
  });
  tearDown(() async {
    await context.output.close();
    root.deleteSync(recursive: true);
  });

  test(
    'Windows link creation injects native calls and preserves directory/file flags',
    () {
      context = CheckoutTestContext(root, (_) => CheckoutTestProcess());
      final directory = Directory(p.join(root.path, 'target-dir'))
        ..createSync();
      final target = File(p.join(root.path, 'target-file'))
        ..writeAsStringSync('file');
      final flags = <int>[];
      final creator = WindowsSwiftPmCheckoutLinkCreator(
        fileSystem: context.fileSystem,
        createLink: (link, text, flag) {
          flags.add(flag);
          return flag & 2 != 0 ? 0 : 1;
        },
        lastError: () => 5,
      );
      creator.create(
        p.join(root.path, 'directory-link'),
        p.basename(directory.path),
      );
      creator.create(p.join(root.path, 'file-link'), p.basename(target.path));
      expect(flags, [3, 1, 2, 0]);
      final failed = WindowsSwiftPmCheckoutLinkCreator(
        fileSystem: context.fileSystem,
        createLink: (_, _, _) => 0,
        lastError: () => 1314,
      );
      expect(
        () => failed.create(p.join(root.path, 'denied'), target.path),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.osError?.errorCode,
            'native error',
            1314,
          ),
        ),
      );
    },
  );

  test(
    'Windows placeholder attributes use configured runner and injected file probing',
    () async {
      context = CheckoutTestContext(root, (_) => CheckoutTestProcess());
      final attributes = WindowsSwiftPmCheckoutAttributes(
        context.runner,
        fileSystem: context.fileSystem,
      );
      await attributes.clear(p.join(root.path, 'missing'));
      expect(context.processes.commands, isEmpty);
      final placeholder = File(p.join(root.path, 'placeholder'))
        ..writeAsStringSync('target');
      await attributes.clear(placeholder.path);
      expect(context.processes.commands.single.arguments, [
        '-R',
        placeholder.path,
      ]);
      expect(context.processes.commands.single.executable, '/fixture/attrib');
    },
  );

  test(
    'Windows fallback owns PowerShell replacement and header identity without host dispatch',
    () async {
      String? scriptPath;
      String? script;
      final payload = File(p.join(root.path, 'payload'))
        ..writeAsStringSync('bytes');
      final link = File(p.join(root.path, 'file-link'))
        ..writeAsStringSync('payload');
      final header = File(p.join(root.path, 'payload.h'))
        ..writeAsStringSync('int value;');
      final headerLink = File(p.join(root.path, 'header-link.h'))
        ..writeAsStringSync('payload.h');
      context = CheckoutTestContext(root, (command) {
        scriptPath = command.arguments.last;
        script = File(scriptPath!).readAsStringSync();
        link.deleteSync();
        payload.copySync(link.path);
        headerLink.deleteSync();
        return CheckoutTestProcess();
      });
      final fallback = WindowsSwiftPmCheckoutFallback(
        runner: context.runner,
        fileSystem: context.fileSystem,
        filesystem: context.filesystem,
        stamps: context.stamps,
        graph: context.graph,
      );
      final records = <Map<String, Object?>>[];
      final changed = await fallback.materialize(
        root.path,
        {link.path: 'aa', headerLink.path: 'bb'},
        {link.path: 'payload', headerLink.path: 'payload.h'},
        {link.path: payload.path, headerLink.path: header.path},
        records,
      );
      expect(changed, isTrue);
      expect(script, contains('New-Item -ItemType HardLink'));
      expect(script, contains('@{ Path ='));
      expect(script, contains('[IO.FileAttributes]::ReadOnly'));
      expect(File(scriptPath!).existsSync(), isFalse);
      expect(context.processes.commands.single.arguments.take(5), [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
      ]);
      expect(headerLink.readAsStringSync(), '#include "payload.h"\n');
      expect(records.map((record) => record['kind']), [
        'hardlink',
        'forwarder',
      ]);
      expect(
        await fallback.materialize(
          root.path,
          {link.path: 'aa', headerLink.path: 'bb'},
          {link.path: 'payload', headerLink.path: 'payload.h'},
          {link.path: payload.path, headerLink.path: header.path},
          <Map<String, Object?>>[],
        ),
        isFalse,
      );
      expect(context.processes.commands, hasLength(1));
    },
  );

  test(
    'Windows fallback process failure cannot publish successful materialization',
    () async {
      context = CheckoutTestContext(root, (_) => CheckoutTestProcess(code: 1));
      final target = File(p.join(root.path, 'payload'))
        ..writeAsStringSync('bytes');
      final placeholder = File(p.join(root.path, 'link'))
        ..writeAsStringSync('payload');
      final fallback = WindowsSwiftPmCheckoutFallback(
        runner: context.runner,
        fileSystem: context.fileSystem,
        filesystem: context.filesystem,
        stamps: context.stamps,
        graph: context.graph,
      );
      await expectLater(
        fallback.materialize(
          root.path,
          {placeholder.path: 'aa'},
          {placeholder.path: 'payload'},
          {placeholder.path: target.path},
          <Map<String, Object?>>[],
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(placeholder.readAsStringSync(), 'payload');
      expect(
        root.listSync().where((entity) => entity.path.endsWith('.ps1')),
        isEmpty,
      );
    },
  );

  test(
    'manifest normalization writes host fixes before dependency rewrites and stamps stable bytes',
    () async {
      context = CheckoutTestContext(root, (_) => CheckoutTestProcess());
      final manifest = File(p.join(root.path, 'Package.swift'))
        ..writeAsStringSync('original');
      final versioned = File(p.join(root.path, 'Package@swift-6.swift'))
        ..writeAsStringSync('original');
      final ignored = File(p.join(root.path, 'README'))
        ..writeAsStringSync('original');
      final attributes = RecordingCheckoutAttributes();
      final normalizer = SwiftPmCheckoutManifestNormalizer(
        fileSystem: context.fileSystem,
        filesystem: context.filesystem,
        attributes: attributes,
        policy: const FixtureVendoredManifestPolicy(),
      );
      var rewrites = 0;
      expect(
        await normalizer.normalizeVendoredPackageManifests(
          root.path,
          consumedProducts: {'Core'},
          rewriteDependencies: (original) async {
            expect(manifest.readAsStringSync(), startsWith('normalized'));
            expect(versioned.readAsStringSync(), startsWith('normalized'));
            rewrites++;
            return '$original rewritten';
          },
        ),
        isTrue,
      );
      expect(rewrites, 2);
      expect(attributes.paths, hasLength(4));
      expect(ignored.readAsStringSync(), 'original');
      final before = manifest.lastModifiedSync();
      expect(
        await normalizer.normalizeVendoredPackageManifests(
          root.path,
          consumedProducts: {'Core'},
        ),
        isTrue,
      );
      final stable = manifest.lastModifiedSync();
      manifest.writeAsStringSync('original');
      await normalizer.normalizeVendoredPackageManifests(
        root.path,
        consumedProducts: {'Core'},
      );
      expect(manifest.lastModifiedSync(), stable);
      expect(stable, isNot(before));
    },
  );
}

@internal
final class RecordingCheckoutAttributes implements SwiftPmCheckoutAttributes {
  final List<String> paths = [];
  @override
  Future<void> clear(String path) async {
    paths.add(path);
  }
}

@internal
final class FixtureVendoredManifestPolicy
    implements SwiftPmVendoredManifestPolicy {
  const FixtureVendoredManifestPolicy();
  @override
  Future<String> normalize(
    String manifest, {
    required String packageDir,
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
  }) async => 'normalized';
}
