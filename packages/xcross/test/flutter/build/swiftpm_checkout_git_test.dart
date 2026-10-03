import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_containment.dart';

import 'support/checkout_test_context.dart';

void main() {
  late Directory root;
  late CheckoutTestContext context;
  setUp(() {
    root = Directory.systemTemp.createTempSync('xcross-checkout-git-');
  });
  tearDown(() async {
    await context.output.close();
    root.deleteSync(recursive: true);
  });

  test(
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
    'reuses matching cloned revision and updates submodules with explicit environment',
    () async {
      context = CheckoutTestContext(
        root,
        (command) => CheckoutTestProcess(
          output: command.arguments.contains('rev-parse')
              ? utf8.encode('revision\n')
              : const [],
        ),
      );
      final destination = Directory(p.join(root.path, 'package'))..createSync();
      Directory(p.join(destination.path, '.git')).createSync();
      File(
        p.join(destination.path, '.gitmodules'),
      ).writeAsStringSync('fixture');
      await context.repository.cloneGitPackage(
        '/fixture/git',
        'https://example.invalid/repo',
        'REVISION',
        destination.path,
      );
      expect(context.processes.commands, hasLength(3));
      expect(
        context.processes.commands[1].arguments,
        containsAllInOrder(['reset', '--hard', 'HEAD']),
      );
      expect(
        context.processes.commands.last.arguments,
        containsAllInOrder([
          'submodule',
          'update',
          '--init',
          '--recursive',
          '--depth',
          '1',
        ]),
      );
      for (final command in context.processes.commands) {
        expect(command.environment?['TOKEN'], 'fixture');
        expect(command.environment?['GIT_TERMINAL_PROMPT'], '0');
      }
    },
  );

  test(
    'failed shallow clone falls back to init, pinned fetch and detached checkout',
    () async {
      context = CheckoutTestContext(
        root,
        (command) => CheckoutTestProcess(
          code: command.arguments.contains('clone') ? 1 : 0,
        ),
      );
      final destination = p.join(root.path, 'package');
      await context.repository.cloneGitPackage(
        '/fixture/git',
        'https://example.invalid/repo',
        'revision',
        destination,
      );
      expect(context.processes.commands, hasLength(4));
      expect(
        context.processes.commands.map((command) => command.arguments),
        containsAllInOrder([
          [
            'clone',
            '--depth',
            '1',
            '--branch',
            'revision',
            'https://example.invalid/repo',
            destination,
          ],
          ['-C', destination, 'init'],
          [
            '-C',
            destination,
            'fetch',
            '--depth',
            '1',
            'https://example.invalid/repo',
            'revision',
          ],
          ['-C', destination, 'checkout', '--detach', 'FETCH_HEAD'],
        ]),
      );
    },
  );

  for (final symlinks in [true, false]) {
    test(
      'rejects indexed destination parent escape before effects, symlinks $symlinks',
      () async {
        final outside = Directory.systemTemp.createTempSync(
          'xcross-checkout-destination-',
        );
        addTearDown(() => outside.deleteSync(recursive: true));
        final sentinel = File(p.join(outside.path, 'link'))
          ..writeAsStringSync('outside sentinel');
        File(p.join(root.path, 'payload')).writeAsStringSync('inside');
        await Link(p.join(root.path, 'dir')).create(outside.path);
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
          fail('No effectful checkout command may run after escape detection');
        });
        await expectLater(
          context.checkout.materializeGitCheckoutSymlinks(
            root.path,
            git: '/fixture/git',
            symlinks: symlinks,
          ),
          throwsA(isA<FlutterBuildError>()),
        );
        expect(sentinel.readAsStringSync(), 'outside sentinel');
        expect(context.processes.commands, hasLength(2));
      },
    );
  }

  test(
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
    test('dangling optional link cache reuse, chain $chain', () async {
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
    });
  }

  test(
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

  test('rejects live link cycles with bounded traversal', () async {
    context = CheckoutTestContext(root, (_) => CheckoutTestProcess());
    await Link(p.join(root.path, 'a')).create('b');
    await Link(p.join(root.path, 'b')).create('a');
    expect(
      () => SwiftPmCheckoutContainment(
        context.fileSystem,
      ).validateTarget(root.path, p.join(root.path, 'a')),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  test(
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
