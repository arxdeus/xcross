import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';

void main() {
  late Directory temp;
  test(
    'isolates simulator build workspace and binary artifacts from device',
    () {
      final environment = {'XCROSS_CACHE_DIR': p.join(temp.path, 'cache')};
      final device = SwiftPmWorkspace.forProject(
        temp.path,
        environment: environment,
      );
      final simulator = SwiftPmWorkspace.forProject(
        temp.path,
        environment: environment,
        simulator: true,
      );
      expect(simulator.root, isNot(device.root));
      expect(simulator.binaryArtifactStore, isNot(device.binaryArtifactStore));
      expect(simulator.packages, isNot(device.packages));
      expect(simulator.scratch, isNot(device.scratch));
      expect(
        SwiftPmWorkspace.forProject(
          temp.path,
          environment: environment,
          simulator: true,
        ).root,
        simulator.root,
      );
    },
  );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('xcross_swiftpm_workspace-');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('uses a stable project key', () {
    final first = SwiftPmWorkspace.forProject(
      temp.path,
      environment: {'XCROSS_CACHE_DIR': p.join(temp.path, 'cache')},
    );
    final second = SwiftPmWorkspace.forProject(
      p.join(temp.path, '.'),
      environment: {'XCROSS_CACHE_DIR': p.join(temp.path, 'cache')},
    );

    expect(second.root, first.root);
    expect(p.basename(first.root), hasLength(16));
  });

  test('uses different keys for different projects', () {
    final firstProject = Directory(p.join(temp.path, 'first'))..createSync();
    final secondProject = Directory(p.join(temp.path, 'second'))..createSync();
    final environment = {'XCROSS_CACHE_DIR': p.join(temp.path, 'cache')};

    final first = SwiftPmWorkspace.forProject(
      firstProject.path,
      environment: environment,
    );
    final second = SwiftPmWorkspace.forProject(
      secondProject.path,
      environment: environment,
    );

    expect(second.root, isNot(first.root));
  });

  test('honors XCROSS_CACHE_DIR', () {
    final cache = p.join(temp.path, 'custom-cache');
    final workspace = SwiftPmWorkspace.forProject(
      temp.path,
      environment: {'XCROSS_CACHE_DIR': cache},
    );

    expect(workspace.cacheRoot, cache);
    expect(p.isWithin(cache, workspace.root), isTrue);
    expect(
      workspace.binaryArtifactStore,
      p.join(cache, 'swiftpm', 'binary-artifacts-v1'),
    );
    expect(
      workspace.binaryArtifactFallback,
      p.join(workspace.root, 'binary-artifacts'),
    );
    expect(workspace.packages, p.join(workspace.root, 'plugins'));
    expect(workspace.scratch, p.join(workspace.root, 'scratch'));
    expect(workspace.vendor, p.join(workspace.root, 'vendor'));
  });

  test('uses LOCALAPPDATA on Windows', () {
    final localAppData = p.join(temp.path, 'local');
    final workspace = SwiftPmWorkspace.forProject(
      temp.path,
      environment: {'LOCALAPPDATA': localAppData},
      windows: true,
    );

    expect(p.isWithin(p.join(localAppData, 'xcross'), workspace.root), isTrue);
  });

  test('uses XDG_CACHE_HOME on POSIX', () {
    final xdg = p.join(temp.path, 'xdg');
    final workspace = SwiftPmWorkspace.forProject(
      temp.path,
      environment: {'XDG_CACHE_HOME': xdg},
      windows: false,
    );

    expect(p.isWithin(p.join(xdg, 'xcross'), workspace.root), isTrue);
  });

  test('falls back to the home cache on POSIX', () {
    final home = p.join(temp.path, 'home');
    final workspace = SwiftPmWorkspace.forProject(
      temp.path,
      environment: {'HOME': home},
      windows: false,
    );

    expect(
      p.isWithin(p.join(home, '.cache', 'xcross'), workspace.root),
      isTrue,
    );
  });
}
