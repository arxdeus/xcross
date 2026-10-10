import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_containment.dart';

import 'support/checkout_test_context.dart';

void main() {
  late Directory root;
  late CheckoutTestContext context;
  setUp(() {
    root = Directory.systemTemp.createTempSync('xcross-checkout-git-');
  });
  tearDown(() async {
    await context.close();
    root.deleteSync(recursive: true);
  });

  test(
    testOn: '!windows',

    'reads detached, loose-ref, packed-ref and linked-worktree HEAD identity',
    () {
      context = CheckoutTestContext(root, (_) => CheckoutTestProcess());
      final git = Directory(p.join(root.path, '.git'))..createSync();
      final head = File(p.join(git.path, 'HEAD'))
        ..writeAsStringSync('detached\n');
      expect(context.repository.gitHeadIdentity(root.path), 'detached');
      head.writeAsStringSync('ref: refs/heads/main\n');
      expect(context.repository.gitHeadIdentity(root.path), isNull);
      final ref = File(p.join(git.path, 'refs/heads/main'))
        ..createSync(recursive: true)
        ..writeAsStringSync('identity\n');
      expect(
        context.repository.gitHeadIdentity(root.path),
        'ref: refs/heads/main\nidentity\n',
      );
      ref.deleteSync();
      File(
        p.join(git.path, 'packed-refs'),
      ).writeAsStringSync('identity refs/heads/main\n');
      expect(
        context.repository.gitHeadIdentity(root.path),
        'ref: refs/heads/main\nidentity refs/heads/main',
      );
      final worktree = Directory(p.join(root.path, 'worktree'))..createSync();
      File(p.join(worktree.path, '.git')).writeAsStringSync('gitdir: ../.git');
      expect(
        context.repository.gitHeadIdentity(worktree.path),
        'ref: refs/heads/main\nidentity refs/heads/main',
      );
    },
  );

  test(
    'batch blobs are drained while feeding requests and preserve large content',
    () async {
      final content = 'x' * 70000;
      final process = CheckoutTestProcess(
        output: utf8.encode('aa blob 70000\n$content\nbb blob 3\nend\n'),
      );
      context = CheckoutTestContext(root, (_) => process);
      final blobs = await context.repository.readGitBlobs(root.path, {
        'aa',
        'bb',
      }, '/fixture/git');
      expect(utf8.decode(blobs['aa']!), content);
      expect(utf8.decode(blobs['bb']!), 'end');
      expect(utf8.decode(process.input.bytes), 'aa\nbb\n');
      expect(context.processes.commands.single.arguments, [
        '-C',
        root.path,
        'cat-file',
        '--batch',
      ]);
    },
  );

  for (final output in [
    'not framed',
    'aa missing\n',
    'aa blob -1\n',
    'aa blob 4\nabc\n',
    'aa blob 3\nabc!',
  ]) {
    test('rejects malformed Git blob response ${output.hashCode}', () async {
      context = CheckoutTestContext(
        root,
        (_) => CheckoutTestProcess(output: utf8.encode(output)),
      );
      await expectLater(
        context.repository.readGitBlobs(root.path, {'aa'}, '/fixture/git'),
        throwsA(isA<FlutterBuildError>()),
      );
    });
  }

  test(
    testOn: '!windows',

    'retargeted stamped ancestor cannot skip live destination containment',
    () async {
      final outsideParent = Directory.systemTemp.createTempSync(
        'xcross-checkout-stamp-outside-',
      );
      addTearDown(() => outsideParent.deleteSync(recursive: true));
      final outside = Directory(p.join(outsideParent.path, 'dir'))
        ..createSync();
      final externalPayload = File(p.join(outsideParent.path, 'payload'))
        ..writeAsStringSync('outside payload');
      await Link(p.join(outside.path, 'link')).create('../payload');
      final sentinel = File(p.join(outside.path, 'keep'))
        ..writeAsStringSync('outside sentinel');
      context = CheckoutTestContext(root, (command) {
        if (command.arguments.contains('ls-files')) {
          return CheckoutTestProcess(
            output: utf8.encode('120000 aa 0\tdir/link\u0000'),
          );
        }
        if (command.arguments.contains('cat-file')) {
          return CheckoutTestProcess(
            output: utf8.encode('aa blob 10\n../payload\n'),
          );
        }
        return CheckoutTestProcess();
      });
      final git = Directory(p.join(root.path, '.git'))..createSync();
      File(p.join(git.path, 'HEAD')).writeAsStringSync('identity');
      File(p.join(root.path, 'payload')).writeAsStringSync('inside');
      final directory = Directory(p.join(root.path, 'dir'))..createSync();
      File(p.join(directory.path, 'link')).writeAsStringSync('../payload');
      expect(
        await context.checkout.materializeGitCheckoutSymlinks(
          root.path,
          git: '/fixture/git',
          symlinks: true,
        ),
        isTrue,
      );
      final count = context.processes.commands.length;
      await directory.rename(p.join(root.path, 'original-dir'));
      await Link(directory.path).create(outside.path);
      await expectLater(
        context.checkout.materializeGitCheckoutSymlinks(
          root.path,
          git: '/fixture/git',
          symlinks: true,
        ),
        throwsA(isA<FlutterBuildError>()),
      );
      expect(context.processes.commands, hasLength(count + 2));
      expect(sentinel.readAsStringSync(), 'outside sentinel');
      expect(externalPayload.readAsStringSync(), 'outside payload');
      expect(Link(p.join(outside.path, 'link')).targetSync(), '../payload');
    },
  );

  for (final chain in [false, true]) {
    test(
      testOn: '!windows',
      'dangling optional link cache reuse, chain $chain',
      () async {
        context = CheckoutTestContext(root, (command) {
          if (command.arguments.contains('ls-files')) {
            return CheckoutTestProcess(
              output: utf8.encode(
                chain
                    ? '120000 aa 0\tExamples/link\u0000120000 bb 0\tExamples/second\u0000'
                    : '120000 aa 0\tExamples/link\u0000',
              ),
            );
          }
          if (command.arguments.contains('cat-file')) {
            return CheckoutTestProcess(
              output: utf8.encode(
                chain
                    ? 'aa blob 6\nsecond\nbb blob 10\n../missing\n'
                    : 'aa blob 10\n../missing\n',
              ),
            );
          }
          return CheckoutTestProcess();
        });
        Directory(p.join(root.path, '.git')).createSync();
        File(p.join(root.path, '.git/HEAD')).writeAsStringSync('identity');
        Directory(p.join(root.path, 'Examples')).createSync();
        File(
          p.join(root.path, 'Package.swift'),
        ).writeAsStringSync('.target(name: "Core", path: "Sources/Core")');
        File(
          p.join(root.path, 'Examples/link'),
        ).writeAsStringSync(chain ? 'second' : '../missing');
        if (chain) {
          File(
            p.join(root.path, 'Examples/second'),
          ).writeAsStringSync('../missing');
        }
        expect(
          await context.checkout.materializeGitCheckoutSymlinks(
            root.path,
            git: '/fixture/git',
            symlinks: true,
          ),
          isTrue,
        );
        final count = context.processes.commands.length;
        expect(
          await context.checkout.materializeGitCheckoutSymlinks(
            root.path,
            git: '/fixture/git',
            symlinks: true,
          ),
          isFalse,
        );
        expect(context.processes.commands, hasLength(count));
      },
    );
  }

  test(
    testOn: '!windows',

    'rejects link hop through outside ancestor returning lexically inside',
    () async {
      context = CheckoutTestContext(root, (_) => CheckoutTestProcess());
      final outside = Directory.systemTemp.createTempSync(
        'xcross-checkout-hop-',
      );
      addTearDown(() => outside.deleteSync(recursive: true));
      await Link(p.join(root.path, 'bridge')).create(outside.path);
      await Link(p.join(root.path, 'chain')).create('bridge/../missing');
      expect(
        () => SwiftPmCheckoutContainment(
          context.fileSystem,
        ).validateTarget(root.path, p.join(root.path, 'chain')),
        throwsA(isA<FlutterBuildError>()),
      );
    },
  );

  for (final warm in [false, true]) {
    test(
      testOn: '!windows',

      'raw indexed target rejects outside intermediary, warm $warm',
      () async {
        final outside = Directory.systemTemp.createTempSync(
          'xcross-checkout-raw-',
        );
        addTearDown(() => outside.deleteSync(recursive: true));
        final sentinel = File(p.join(outside.path, 'keep'))
          ..writeAsStringSync('sentinel');
        const target = '../bridge/../missing';
        context = CheckoutTestContext(root, (command) {
          if (command.arguments.contains('ls-files')) {
            return CheckoutTestProcess(
              output: utf8.encode('120000 aa 0\tExamples/link\u0000'),
            );
          }
          if (command.arguments.contains('cat-file')) {
            return CheckoutTestProcess(
              output: utf8.encode('aa blob ${target.length}\n$target\n'),
            );
          }
          return CheckoutTestProcess();
        });
        Directory(p.join(root.path, '.git')).createSync();
        File(p.join(root.path, '.git/HEAD')).writeAsStringSync('identity');
        Directory(p.join(root.path, 'Examples')).createSync();
        File(
          p.join(root.path, 'Package.swift'),
        ).writeAsStringSync('.target(name: "Core", path: "Sources/Core")');
        File(p.join(root.path, 'Examples/link')).writeAsStringSync(target);
        final bridge = Directory(p.join(root.path, 'bridge'));
        if (warm) {
          bridge.createSync();
          expect(
            await context.checkout.materializeGitCheckoutSymlinks(
              root.path,
              git: '/fixture/git',
              symlinks: true,
            ),
            isTrue,
          );
          final count = context.processes.commands.length;
          expect(
            await context.checkout.materializeGitCheckoutSymlinks(
              root.path,
              git: '/fixture/git',
              symlinks: true,
            ),
            isFalse,
          );
          expect(context.processes.commands, hasLength(count));
          bridge.deleteSync();
        }
        await Link(bridge.path).create(outside.path);
        final count = context.processes.commands.length;
        await expectLater(
          context.checkout.materializeGitCheckoutSymlinks(
            root.path,
            git: '/fixture/git',
            symlinks: true,
          ),
          throwsA(isA<FlutterBuildError>()),
        );
        expect(context.processes.commands, hasLength(count + 2));
        expect(sentinel.readAsStringSync(), 'sentinel');
        if (!warm) {
          expect(
            File(p.join(root.path, 'Examples/link')).readAsStringSync(),
            target,
          );
        }
      },
    );
  }

  test(
    testOn: '!windows',

    'cold raw components resolve planned indexed placeholders before parent traversal',
    () async {
      context = CheckoutTestContext(root, (command) {
        if (command.arguments.contains('ls-files')) {
          return CheckoutTestProcess(
            output: utf8.encode('120000 aa 0\ta\u0000120000 bb 0\tlink\u0000'),
          );
        }
        if (command.arguments.contains('cat-file')) {
          return CheckoutTestProcess(
            output: utf8.encode('aa blob 1\n.\nbb blob 12\na/../outside\n'),
          );
        }
        fail('No checkout may run after planned-link escape detection');
      });
      File(p.join(root.path, 'a')).writeAsStringSync('.');
      File(p.join(root.path, 'link')).writeAsStringSync('a/../outside');
      File(p.join(root.path, 'outside')).writeAsStringSync('inside sentinel');
      await expectLater(
        context.checkout.materializeGitCheckoutSymlinks(
          root.path,
          git: '/fixture/git',
          symlinks: true,
        ),
        throwsA(isA<FlutterBuildError>()),
      );
      expect(context.processes.commands, hasLength(2));
      expect(File(p.join(root.path, 'a')).readAsStringSync(), '.');
      expect(
        File(p.join(root.path, 'link')).readAsStringSync(),
        'a/../outside',
      );
      expect(
        File(p.join(root.path, 'outside')).readAsStringSync(),
        'inside sentinel',
      );
    },
  );

  test(
    testOn: '!windows',

    'direct link entrypoint rejects planned raw target before any effects',
    () async {
      context = CheckoutTestContext(
        root,
        (_) => fail('No process may start for escaping raw target'),
      );
      final a = p.join(root.path, 'a');
      final link = p.join(root.path, 'link');
      File(a).writeAsStringSync('.');
      File(link).writeAsStringSync('a/../outside');
      final records = <Map<String, Object?>>[];
      await expectLater(
        context.links.materializeAsSymlinks(
          root.path,
          {a: 'aa', link: 'bb'},
          {a: '.', link: 'a/../outside'},
          {a: root.path, link: p.join(root.path, 'outside')},
          '/fixture/git',
          records,
        ),
        throwsA(isA<FlutterBuildError>()),
      );
      expect(context.processes.commands, isEmpty);
      expect(records, isEmpty);
      expect(File(a).readAsStringSync(), '.');
      expect(File(link).readAsStringSync(), 'a/../outside');
    },
  );

  test(
    testOn: '!windows',
    'rejects live link cycles with bounded traversal',
    () async {
      context = CheckoutTestContext(root, (_) => CheckoutTestProcess());
      await Link(p.join(root.path, 'a')).create('b');
      await Link(p.join(root.path, 'b')).create('a');
      expect(
        () => SwiftPmCheckoutContainment(
          context.fileSystem,
        ).validateTarget(root.path, p.join(root.path, 'a')),
        throwsA(isA<FlutterBuildError>()),
      );
    },
  );

  test(
    testOn: '!windows',

    'materialization restores symlinks and unchanged HEAD stamp avoids all processes',
    () async {
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
      final git = Directory(p.join(root.path, '.git'))..createSync();
      File(p.join(git.path, 'HEAD')).writeAsStringSync('identity');
      File(p.join(root.path, 'payload')).writeAsStringSync('actual');
      File(p.join(root.path, 'link')).writeAsStringSync('payload');
      expect(
        await context.checkout.materializeGitCheckoutSymlinks(
          root.path,
          git: '/fixture/git',
          symlinks: true,
        ),
        isTrue,
      );
      expect(Link(p.join(root.path, 'link')).targetSync(), 'payload');
      final count = context.processes.commands.length;
      expect(
        await context.checkout.materializeGitCheckoutSymlinks(
          root.path,
          git: '/fixture/git',
          symlinks: true,
        ),
        isFalse,
      );
      expect(context.processes.commands, hasLength(count));
      expect(
        context.processes.commands.last.arguments,
        containsAllInOrder([
          'core.symlinks=true',
          '-C',
          root.path,
          'checkout',
          '--force',
          '--pathspec-from-file=-',
          '--pathspec-file-nul',
          '--',
        ]),
      );
    },
  );
}
