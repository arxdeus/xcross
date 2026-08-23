import 'dart:async';

import 'package:args/command_runner.dart';
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/update_command.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/git_update_ref_resolver.dart';
import 'package:xcross/src/update/install_layout.dart';

void main() {
  group('UpdateCommand parser', () {
    test('supports --ref and no longer exposes --to', () {
      final command = UpdateCommand();

      expect(command.argParser.options, contains('ref'));
      expect(command.argParser.options, isNot(contains('to')));
    });

    test('--ref help requires a full commit SHA', () {
      final command = UpdateCommand();

      expect(
        command.argParser.options['ref']!.help,
        contains('full 40-character commit SHA'),
      );
    });
  });

  group('UpdateCommand', () {
    test('latest release lookup runs inside a step', () async {
      final command = UpdateCommand.withSeams(
        latestTagLookup: () async => '1.3.0',
        currentVersion: () => '1.2.0',
      );

      final lines = await _captureAsync(() async {
        await _run(command, ['update', '--check']);
      });

      expect(
        lines.where((line) => line.contains('Checking latest release')),
        isNotEmpty,
      );
    });

    test('ref resolution runs inside a step', () async {
      final command = UpdateCommand.withSeams(
        resolveRef: (ref) async => const GitUpdateRef(
          kind: GitUpdateRefKind.branch,
          displayName: 'main',
          fetchRef: 'refs/heads/main',
          commitSha: _shaB,
        ),
      );

      final lines = await _captureAsync(() async {
        await _run(command, ['update', '--check', '--ref', 'main']);
      });

      expect(
        lines.where((line) => line.contains('Resolving ref main')),
        isNotEmpty,
      );
    });
    test(
      'without --ref and --check looks up latest release and does not install',
      () async {
        var latestLookups = 0;
        var releaseInstalls = 0;
        var sourceInstalls = 0;
        var layoutResolves = 0;
        var assetNameCalls = 0;
        final command = UpdateCommand.withSeams(
          latestTagLookup: () async {
            latestLookups++;
            return '1.3.0';
          },
          resolveInstallLayout: () {
            layoutResolves++;
            return _layout;
          },
          assetName: () {
            assetNameCalls++;
            return 'unused';
          },
          installRelease: ({required layout, required tag}) async {
            releaseInstalls++;
          },
          installSourceRef: ({required layout, required ref}) async {
            sourceInstalls++;
          },
          currentVersion: () => '1.2.0',
        );

        await _run(command, ['update', '--check']);

        expect(latestLookups, 1);
        expect(releaseInstalls, 0);
        expect(sourceInstalls, 0);
        expect(layoutResolves, 0);
        expect(assetNameCalls, 0);
      },
    );

    test('routes explicit tag refs to release installs', () async {
      final releaseTags = <String>[];
      final sourceInstalls = <GitUpdateRef>[];
      final resolvedRefs = <String>[];
      final assetNameCalls = <String>[];
      final command = UpdateCommand.withSeams(
        resolveRef: (ref) async {
          resolvedRefs.add(ref);
          return const GitUpdateRef(
            kind: GitUpdateRefKind.tag,
            displayName: '1.4.0',
            fetchRef: 'refs/tags/1.4.0',
            commitSha: _shaA,
          );
        },
        resolveInstallLayout: () => _layout,
        assetName: () {
          assetNameCalls.add('asset');
          return 'xcross-linux-x64.tar.gz';
        },
        installRelease: ({required layout, required tag}) async {
          releaseTags.add(tag);
        },
        installSourceRef: ({required layout, required ref}) async {
          sourceInstalls.add(ref);
        },
      );

      await _run(command, ['update', '--ref', '1.4.0', '--yes']);

      expect(resolvedRefs, ['1.4.0']);
      expect(releaseTags, ['1.4.0']);
      expect(sourceInstalls, isEmpty);
      expect(assetNameCalls, ['asset']);
    });

    test('routes explicit branch refs to source installs', () async {
      final sourceInstalls = <GitUpdateRef>[];
      var assetNameCalls = 0;
      final command = UpdateCommand.withSeams(
        resolveRef: (ref) async => const GitUpdateRef(
          kind: GitUpdateRefKind.branch,
          displayName: 'main',
          fetchRef: 'refs/heads/main',
          commitSha: _shaB,
        ),
        resolveInstallLayout: () => _layout,
        assetName: () {
          assetNameCalls++;
          return 'should-not-be-used';
        },
        installRelease: ({required layout, required tag}) {
          fail('release install must not run for source refs');
        },
        installSourceRef: ({required layout, required ref}) async {
          sourceInstalls.add(ref);
        },
      );

      await _run(command, ['update', '--ref', 'main', '--yes']);

      expect(sourceInstalls, hasLength(1));
      expect(sourceInstalls.single.kind, GitUpdateRefKind.branch);
      expect(sourceInstalls.single.displayName, 'main');
      expect(assetNameCalls, 0);
    });

    test('routes explicit commit refs to source installs', () async {
      final sourceInstalls = <GitUpdateRef>[];
      final command = UpdateCommand.withSeams(
        resolveRef: (ref) async => const GitUpdateRef(
          kind: GitUpdateRefKind.commit,
          displayName: 'feature-head',
          fetchRef: 'feature-head',
          commitSha: _shaC,
        ),
        resolveInstallLayout: () => _layout,
        assetName: () {
          fail('assetName must not run for source refs');
        },
        installRelease: ({required layout, required tag}) {
          fail('release install must not run for source refs');
        },
        installSourceRef: ({required layout, required ref}) async {
          sourceInstalls.add(ref);
        },
      );

      await _run(command, ['update', '--ref', 'feature-head', '--yes']);

      expect(sourceInstalls, hasLength(1));
      expect(sourceInstalls.single.kind, GitUpdateRefKind.commit);
      expect(sourceInstalls.single.commitSha, _shaC);
    });

    test(
      '--check --ref reports the resolved ref and does not install',
      () async {
        var layoutResolves = 0;
        var assetNameCalls = 0;
        var releaseInstalls = 0;
        var sourceInstalls = 0;
        final reports = <({String requestedRef, GitUpdateRef resolvedRef})>[];
        final command = UpdateCommand.withSeams(
          resolveRef: (ref) async => const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'stable',
            fetchRef: 'refs/heads/stable',
            commitSha: _shaB,
          ),
          resolveInstallLayout: () {
            layoutResolves++;
            return _layout;
          },
          assetName: () {
            assetNameCalls++;
            return 'unused';
          },
          installRelease: ({required layout, required tag}) async {
            releaseInstalls++;
          },
          installSourceRef: ({required layout, required ref}) async {
            sourceInstalls++;
          },
          reportResolvedRef: ({required requestedRef, required resolvedRef}) {
            reports.add((requestedRef: requestedRef, resolvedRef: resolvedRef));
          },
        );

        await _run(command, ['update', '--check', '--ref', 'stable']);

        expect(layoutResolves, 0);
        expect(assetNameCalls, 0);
        expect(releaseInstalls, 0);
        expect(sourceInstalls, 0);
        expect(reports, hasLength(1));
        expect(reports.single.requestedRef, 'stable');
        expect(reports.single.resolvedRef.displayName, 'stable');
        expect(reports.single.resolvedRef.kind, GitUpdateRefKind.branch);
        expect(reports.single.resolvedRef.commitSha, _shaB);
      },
    );

    test(
      'rejects explicit tag refs whose display name is not a semver tag',
      () async {
        final command = UpdateCommand.withSeams(
          resolveRef: (ref) async => const GitUpdateRef(
            kind: GitUpdateRefKind.tag,
            displayName: 'nightly',
            fetchRef: 'refs/tags/nightly',
            commitSha: _shaA,
          ),
          resolveInstallLayout: () => _layout,
          assetName: () => 'unused',
          installRelease: ({required layout, required tag}) async {},
          installSourceRef: ({required layout, required ref}) async {},
        );

        await expectLater(
          () => _run(command, ['update', '--ref', 'nightly', '--yes']),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              contains(
                'release tag "nightly" is not a version xcross can read',
              ),
            ),
          ),
        );
      },
    );

    test(
      'explicit refs install even when force is absent and versions match',
      () async {
        final releaseTags = <String>[];
        final command = UpdateCommand.withSeams(
          resolveRef: (ref) async => const GitUpdateRef(
            kind: GitUpdateRefKind.tag,
            displayName: '1.2.0',
            fetchRef: 'refs/tags/1.2.0',
            commitSha: _shaA,
          ),
          resolveInstallLayout: () => _layout,
          assetName: () => 'xcross-linux-x64.tar.gz',
          installRelease: ({required layout, required tag}) {
            releaseTags.add(tag);
            return Future<void>.value();
          },
          installSourceRef: ({required layout, required ref}) async {},
          currentVersion: () => '1.2.0',
        );

        await _run(command, ['update', '--ref', '1.2.0', '--yes']);

        expect(releaseTags, ['1.2.0']);
      },
    );

    test(
      'installed dev builds are not rejected before explicit ref routing',
      () async {
        final sourceInstalls = <GitUpdateRef>[];
        final command = UpdateCommand.withSeams(
          resolveRef: (ref) async => const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: _shaB,
          ),
          resolveInstallLayout: () => _layout,
          assetName: () {
            fail('assetName must not run for source refs');
          },
          installRelease: ({required layout, required tag}) => Future.sync(
            () => fail('release install must not run for source refs'),
          ),
          installSourceRef: ({required layout, required ref}) async {
            sourceInstalls.add(ref);
          },
          currentVersion: () => '1.2.0-dev',
        );

        await _run(command, ['update', '--ref', 'main', '--yes']);

        expect(sourceInstalls, hasLength(1));
        expect(sourceInstalls.single.commitSha, _shaB);
      },
    );

    test(
      'unreleased build always installs the latest official release',
      () async {
        final installed = <String>[];
        final command = UpdateCommand.withSeams(
          latestTagLookup: () async => '1.2.1',
          resolveInstallLayout: () => _layout,
          assetName: () => 'xcross-linux-x64.tar.gz',
          installRelease: ({required layout, required tag}) async {
            installed.add(tag);
          },
          installSourceRef: ({required layout, required ref}) async {},
          currentVersion: () => '9.9.9',
          currentIsReleased: () => false,
        );

        await _run(command, ['update', '--yes']);

        expect(installed, ['1.2.1']);
      },
    );

    test(
      'without --ref and without force skips install when already current',
      () async {
        var latestLookups = 0;
        var releaseInstalls = 0;
        final command = UpdateCommand.withSeams(
          latestTagLookup: () async {
            latestLookups++;
            return '1.2.0';
          },
          resolveInstallLayout: () => _layout,
          assetName: () => 'xcross-linux-x64.tar.gz',
          installRelease: ({required layout, required tag}) async {
            releaseInstalls++;
          },
          installSourceRef: ({required layout, required ref}) async {},
          currentVersion: () => '1.2.0',
          currentIsReleased: () => true,
        );

        await _run(command, ['update']);

        expect(latestLookups, 1);
        expect(releaseInstalls, 0);
      },
    );
  });
}

Future<void> _run(UpdateCommand command, List<String> args) async {
  final runner = CommandRunner<void>('xcross', 'test')..addCommand(command);
  await runner.run(args);
}

const _layout = InstallLayout(
  binaryPath: '/opt/xcross/bin/xcross',
  binDir: '/opt/xcross/bin',
  libDir: '/opt/xcross/lib',
);

const _shaA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _shaB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _shaC = 'cccccccccccccccccccccccccccccccccccccccc';

Future<List<String>> _captureAsync(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, __, ___, line) => lines.add(line),
    ),
  );
  return lines;
}
