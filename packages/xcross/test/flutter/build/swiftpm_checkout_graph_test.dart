import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

import 'support/checkout_test_context.dart';

void main() {
  late Directory root;
  late CheckoutTestContext context;
  setUp(() {
    root = Directory.systemTemp.createTempSync('xcross-checkout-graph-');
    context = CheckoutTestContext(root, (_) => CheckoutTestProcess());
  });
  tearDown(() async {
    await context.output.close();
    root.deleteSync(recursive: true);
  });

  test(
    'index extracts only symlink objects and rejects escaping index paths',
    () {
      final links = context.graph.indexLinks(
        root.path,
        '100644 ab 0\tnormal\u0000120000 cd 0\tSources/link\u0000',
      );
      expect(links, {p.join(root.path, 'Sources/link'): 'cd'});
      for (final path in [
        '../outside',
        p.join(p.dirname(root.path), 'outside'),
      ]) {
        expect(
          () => context.graph.indexLinks(root.path, '120000 cd 0\t$path\u0000'),
          throwsA(isA<FlutterBuildError>()),
        );
      }
    },
  );

  test('resolves chained relative links and rejects cycles and traversal', () {
    final first = p.join(root.path, 'first');
    final second = p.join(root.path, 'second');
    expect(
      context.graph.resolveTargets(root.path, {
        first: 'second',
        second: 'payload',
      }),
      {
        first: p.join(root.path, 'payload'),
        second: p.join(root.path, 'payload'),
      },
    );
    expect(
      () => context.graph.resolveTargets(root.path, {
        first: 'second',
        second: 'first',
      }),
      throwsA(isA<FlutterBuildError>()),
    );
    expect(
      () => context.graph.resolveTargets(root.path, {first: '../outside'}),
      throwsA(isA<FlutterBuildError>()),
    );
    expect(
      () => context.graph.resolveTargets(root.path, {
        first: p.join(p.dirname(root.path), 'outside'),
      }),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  test(
    'allows dangling optional links only for empirical symlink capability',
    () {
      File(p.join(root.path, 'Package.swift')).writeAsStringSync(
        'let package = Package(targets: [.target(name: "Core")])',
      );
      final optional = p.join(root.path, 'Examples', 'optional');
      final target = p.join(root.path, 'missing');
      context.graph.validateTargets(
        root.path,
        {optional: '../missing'},
        {optional: target},
        symlinks: true,
      );
      expect(
        () => context.graph.validateTargets(
          root.path,
          {optional: '../missing'},
          {optional: target},
          symlinks: false,
        ),
        throwsA(isA<FlutterBuildError>()),
      );
      final required = p.join(root.path, 'Sources', 'Core', 'header.h');
      expect(
        () => context.graph.validateTargets(
          root.path,
          {required: 'missing'},
          {required: target},
          symlinks: true,
        ),
        throwsA(isA<FlutterBuildError>()),
      );
    },
  );

  test(
    'rejects existing file and directory links escaping the checkout',
    () async {
      final outside = Directory.systemTemp.createTempSync(
        'xcross-checkout-outside-',
      );
      addTearDown(() => outside.deleteSync(recursive: true));
      final external = File(p.join(outside.path, 'payload'))
        ..writeAsStringSync('safe');
      final target = p.join(root.path, 'external');
      await Link(target).create(external.path);
      final link = p.join(root.path, 'new-link');
      expect(
        () => context.graph.validateTargets(
          root.path,
          {link: 'external'},
          {link: target},
          symlinks: true,
        ),
        throwsA(isA<FlutterBuildError>()),
      );
      await Link(target).delete();
      await Link(target).create(outside.path);
      expect(
        () => context.graph.validateTargets(
          root.path,
          {link: 'external/missing'},
          {link: p.join(target, 'missing')},
          symlinks: true,
        ),
        throwsA(isA<FlutterBuildError>()),
      );
      expect(external.readAsStringSync(), 'safe');
    },
  );

  test(
    'rejects an existing destination alias that leaves the checkout',
    () async {
      final outside = Directory.systemTemp.createTempSync(
        'xcross-checkout-leaf-outside-',
      );
      addTearDown(() => outside.deleteSync(recursive: true));
      final sentinel = File(p.join(outside.path, 'keep'))
        ..writeAsStringSync('outside sentinel');
      final payload = File(p.join(root.path, 'payload'))
        ..writeAsStringSync('inside');
      final destination = p.join(root.path, 'directory-alias');
      await Link(destination).create(outside.path);
      expect(
        () => context.graph.validateTargets(
          root.path,
          {destination: 'payload'},
          {destination: payload.path},
          symlinks: false,
        ),
        throwsA(isA<FlutterBuildError>()),
      );
      expect(sentinel.readAsStringSync(), 'outside sentinel');
    },
  );

  test(
    'declared exclusions permit optional links while sources/resources remain required',
    () {
      File(p.join(root.path, 'Package.swift')).writeAsStringSync(
        'let package = Package(targets: [.target(name: "Core", exclude: ["optional"], sources: ["main"], resources: [.copy("asset")])])',
      );
      expect(
        context.graph.requiredPackageLink(
          root.path,
          p.join(root.path, 'Sources', 'Core', 'optional'),
        ),
        isFalse,
      );
      expect(
        context.graph.requiredPackageLink(
          root.path,
          p.join(root.path, 'Sources', 'Core', 'main', 'header.h'),
        ),
        isTrue,
      );
      expect(
        context.graph.requiredPackageLink(
          root.path,
          p.join(root.path, 'Sources', 'Core', 'asset'),
        ),
        isTrue,
      );
    },
  );

  test(
    'orders nested link targets before copying their containing directory',
    () {
      final target = Directory(p.join(root.path, 'tree'))..createSync();
      final outer = p.join(root.path, 'outer');
      final nested = p.join(target.path, 'nested');
      final order = context.graph.order(
        {outer: 'one', nested: 'two'},
        {outer: target.path, nested: p.join(root.path, 'payload')},
      );
      expect(order, [nested, outer]);
      expect(
        () => context.graph.order({outer: 'one'}, {outer: root.path}),
        throwsA(isA<FlutterBuildError>()),
      );
    },
  );

  test(
    'stamp validators own filesystem shape checks without checkout cycles',
    () async {
      final target = File(p.join(root.path, 'payload'))
        ..writeAsStringSync('content');
      final link = p.join(root.path, 'link');
      await Link(link).create('payload');
      final stamp = File(p.join(root.path, 'stamp'))
        ..writeAsStringSync(
          jsonEncode({
            'version': 3,
            'fingerprint': 'identity',
            'links': [
              {
                'path': link,
                'kind': 'symlink',
                'target': 'payload',
                'directory': false,
              },
            ],
          }),
        );
      expect(
        context.stamps.materializedLinksIntact(
          stamp,
          'identity',
          root: root.path,
        ),
        isTrue,
      );
      expect(
        context.stamps.materializedLinksIntact(stamp, 'other', root: root.path),
        isFalse,
      );
      expect(
        context.stamps.linkIntact(link, 'symlink', 'payload', directory: true),
        isFalse,
      );
      await Link(link).delete();
      target.deleteSync();
      expect(
        context.stamps.materializedLinksIntact(
          stamp,
          'identity',
          root: root.path,
        ),
        isFalse,
      );
      final placeholder = File(link)..writeAsStringSync('payload');
      expect(context.stamps.linkIntact(link, 'hardlink', 'payload'), isFalse);
      placeholder.writeAsStringSync('actual');
      expect(context.stamps.linkIntact(link, 'hardlink', 'payload'), isTrue);
      expect(context.stamps.linkIntact(link, 'forwarder', 'actual'), isTrue);
    },
  );
}
