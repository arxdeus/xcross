import 'dart:convert';
import 'dart:io';

import 'acquisition_fixtures.dart';
import 'check.dart';
import 'declaration_fixtures.dart';
import 'dependency_fixtures.dart';
import 'platform_fixtures.dart';
import 'workspace_inventory.dart';

Future<void> main() async {
  final scratch =
      Platform.environment['JCODE_SCRATCH_DIR'] ?? Directory.systemTemp.path;
  final directory = Directory('$scratch/architecture-fixtures-$pid');
  directory.createSync(recursive: true);
  final config =
      jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
          as Map<String, dynamic>;
  final base = File('.dart_tool/package_config.json').absolute.uri;
  for (final package
      in (config['packages'] as List<dynamic>).cast<Map<String, dynamic>>()) {
    package['rootUri'] = base.resolve(package['rootUri'] as String).toString();
  }
  final packageFile = File('${directory.path}/.dart_tool/package_config.json');
  packageFile.parent.createSync(recursive: true);
  packageFile.writeAsStringSync(jsonEncode(config));
  final cases = {
    ...acquisitionFixtures(),
    ...platformFixtures(),
    ...declarationFixtures(),
    ...dependencyFixtures(),
  };
  final expected = <String, Set<String>>{};
  for (final entry in cases.entries) {
    final path = 'packages/fixture/lib/src/shared/${entry.key}.dart';
    final file = File('${directory.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value.$1);
    expected[path] = entry.value.$2;
  }
  for (final entry in dependencyAssets().entries) {
    final file = File('${directory.path}/${entry.key}');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value.$1);
    expected[entry.key] = entry.value.$2;
  }

  var failed = false;
  try {
    final violations = await inspectFiles(
      directory.path,
      expected.keys.toList(),
    );
    for (final entry in expected.entries) {
      final actual = violations
          .where((v) => v.path == entry.key)
          .map((v) => v.rule)
          .toSet();
      if (actual.difference(entry.value).isNotEmpty ||
          entry.value.difference(actual).isNotEmpty) {
        stderr.writeln('${entry.key}: expected ${entry.value}, actual $actual');
        failed = true;
      }
    }
    const nativePath =
        'packages/xcross/lib/src/composition/native_runtime.dart';
    final nativeSource = dependencyAssets()[nativePath]!.$1;
    final approvedCall = nativeSource.indexOf('detectPlatformHostSnapshot()');
    final deniedCall = nativeSource.indexOf(
      'detectPlatformHostSnapshot()',
      approvedCall + 1,
    );
    if (violations.any(
          (v) => v.path == nativePath && v.offset == approvedCall,
        ) ||
        !violations.any(
          (v) =>
              v.path == nativePath &&
              v.offset == deniedCall &&
              v.rule == 'hidden-detection',
        )) {
      throw StateError('Exact native caller approval failed');
    }
    final hostSource = dependencyAssets()[hostComposition]!.$1;
    final approvedSwitch = hostSource.indexOf('switch(host)');
    final deniedSwitch = hostSource.indexOf('switch(inner)');
    if (violations.any(
          (v) => v.path == hostComposition && v.offset == approvedSwitch,
        ) ||
        !violations.any(
          (v) =>
              v.path == hostComposition &&
              v.offset == deniedSwitch &&
              v.rule == 'platform-branch',
        )) {
      throw StateError('Exact top-level selector approval failed');
    }
    final detectorSource = dependencyAssets()[detector]!.$1;
    final detectorAllowed = detectorSource.indexOf('Platform.operatingSystem');
    final detectorDenied = detectorSource.indexOf(
      'Platform.operatingSystem',
      detectorAllowed + 1,
    );
    if (violations.any(
          (v) =>
              v.path == detector &&
              v.offset == detectorAllowed + 'Platform.'.length,
        ) ||
        !violations.any(
          (v) =>
              v.path == detector &&
              v.offset == detectorDenied + 'Platform.'.length &&
              v.rule == 'ambient-detection',
        )) {
      throw StateError('Exact native read purpose failed');
    }
    const hookPath = 'packages/apple_developer_kit/hook/build.dart';
    final hookSource = dependencyAssets()[hookPath]!.$1;
    final hookAllowed = hookSource.indexOf('if(input == OS.windows)');
    final hookDenied = hookSource.indexOf(
      "if(host.operatingSystem == 'windows')",
    );
    final hookNested = hookSource.indexOf('if(inner == OS.windows)');
    final hookAlias = hookSource.indexOf('if(label == OS.windows.toString())');
    if (violations.any((v) => v.path == hookPath && v.offset == hookAllowed) ||
        ![hookDenied, hookNested, hookAlias].every(
          (offset) => violations.any(
            (v) =>
                v.path == hookPath &&
                v.offset == offset &&
                v.rule == 'platform-branch',
          ),
        )) {
      throw StateError('Exact native build input purpose failed');
    }
    const assemblyPath =
        'packages/apple_developer_kit/lib/src/composition/native_library_loader.dart';
    final assemblySource = dependencyAssets()[assemblyPath]!.$1;
    final approvedImport = assemblySource.indexOf('import');
    final deniedImport = assemblySource.indexOf('import', approvedImport + 1);
    if (violations.any(
          (v) => v.path == assemblyPath && v.offset == approvedImport,
        ) ||
        !violations.any(
          (v) =>
              v.path == assemblyPath &&
              v.offset == deniedImport &&
              v.rule == 'concrete-edge',
        )) {
      throw StateError('Exact assembly destination permission failed');
    }
    const physicalPath =
        'packages/xcross/lib/src/composition/cli/flutter_run_command.dart';
    final physicalSource = dependencyAssets()[physicalPath]!.$1;
    final physicalAllowed = physicalSource.indexOf('import');
    final physicalDenied = physicalSource.indexOf(
      'import',
      physicalAllowed + 1,
    );
    if (violations.any(
          (v) => v.path == physicalPath && v.offset == physicalAllowed,
        ) ||
        !violations.any(
          (v) =>
              v.path == physicalPath &&
              v.offset == physicalDenied &&
              v.rule == 'concrete-edge',
        )) {
      throw StateError('Exact fixed-physical assembly permission failed');
    }
    const metadataPath =
        'packages/fixture/lib/src/host/windows/release_metadata.dart';
    final metadataSource = dependencyAssets()[metadataPath]!.$1;
    final interpolationControls = [
      metadataSource.indexOf(
        'if(',
        metadataSource.indexOf('String interpolated('),
      ),
      metadataSource.indexOf(
        'switch(',
        metadataSource.indexOf('String switchEffect('),
      ),
      metadataSource.indexOf(
        'host.architecture ==',
        metadataSource.indexOf('String conditionalEffect('),
      ),
    ];
    if (!interpolationControls.every(
      (offset) =>
          offset >= 0 &&
          violations.any(
            (v) =>
                v.path == metadataPath &&
                v.offset == offset &&
                v.rule == 'platform-branch',
          ),
    )) {
      throw StateError('Effectful interpolation accepted as metadata');
    }
    final scopedPairs = {
      'packages/xcross/tool/swiftpm_binary_fixture.dart': 'void other()',
      'packages/xcross/tool/verify_flutter_notices.dart':
          "stderr.writeln('unapproved')",

      'packages/fixture/lib/src/host/windows/release_metadata.dart':
          'String backend(',
      'packages/apple_developer_kit/lib/src/host/linux/adi/linux_native_library_loader.dart':
          'Object other()',
      'packages/apple_developer_kit/lib/src/host/macos/adi/macos_native_library_loader.dart':
          'Object other()',
      'packages/apple_developer_kit/lib/src/host/windows/adi/loader/loader_windows.dart':
          'Object other()',
      'packages/xcross/lib/src/host/macos/compose/macos_compose_host.dart':
          'bool other(',
      'packages/xcross/lib/src/composition/xcrun_sdk.dart': 'Object other(',
    };
    for (final entry in scopedPairs.entries) {
      final source = dependencyAssets()[entry.key]!.$1;
      final boundary = source.indexOf(entry.value);
      final findings = violations.where((v) => v.path == entry.key).toList();
      if (boundary < 0 ||
          findings.isEmpty ||
          findings.any((v) => v.offset < boundary)) {
        throw StateError(
          'Approved purpose incorrectly rejected at ${entry.key}: ${findings.map((v) => v.toJson()).toList()}',
        );
      }
    }
    if (classify(
              'packages/fixture/lib/src/host/windows/target/simulator/a.dart',
            ).host !=
            'windows' ||
        classify(
              'packages/fixture/lib/src/host/windows/target/simulator/a.dart',
            ).target !=
            'simulator') {
      throw StateError('Cross-specific classification failed');
    }
    if (!production('packages/cli_kit/hook/build.dart') ||
        !production('packages/cli_kit/src/bridge.c') ||
        production('packages/cli_kit/test/a.dart')) {
      throw StateError('Production inventory failed');
    }
    for (final host in ['linux', 'macos']) {
      final classified = classify(
        'packages/xcross/lib/src/composition/flutter/${host}_flutter_feature_services.dart',
      );
      if (classified.host != host || classified.kind != 'host-composition') {
        throw StateError(
          'Exact selected host composition classification failed',
        );
      }
    }
    const approvedPart =
        'packages/xcross/lib/src/composition/cli/flutter_build_command.g.dart';
    File('${directory.path}/$approvedPart').writeAsStringSync(
      "part of 'compose_build_command.dart'; class Parser {}",
    );
    final wrongPart = await inspectFiles(directory.path, [approvedPart]);
    if (!wrongPart.any((v) => v.rule == 'inventory')) {
      throw StateError('Unapproved generated part owner accepted');
    }
    final duplicate = File('${directory.path}/$hostComposition');
    duplicate.writeAsStringSync(
      'abstract class WindowsHostInterface {} int composeXcrossHost(Object host) { final first = switch(host) { WindowsHostInterface() => 1, _ => 2 }; return first + switch(host) { WindowsHostInterface() => 1, _ => 2 }; }',
    );
    final multiple = await inspectFiles(directory.path, [hostComposition]);
    if (!multiple.any((v) => v.rule == 'selector-count')) {
      throw StateError('Repeated composition selection accepted');
    }
    if (classify('.github/scripts/simulator_smoke.py').host != 'macos' ||
        classify('.github/scripts/simulator_smoke.py').target != 'simulator' ||
        classify('.github/FUNDING.yml').kind != 'ci-metadata') {
      throw StateError('Exact CI axes failed');
    }
    final manifest =
        'workspace:\n${workspacePackages.map((p) => '  - packages/$p').join('\n')}\n';
    if (workspaceViolations(manifest, []).isNotEmpty ||
        workspaceViolations(
          '$manifest  - packages/new_package\n',
          [],
        ).isEmpty ||
        workspaceViolations(manifest, [
          'packages/unknown/lib/a.dart',
        ]).isEmpty) {
      throw StateError('Fail-closed workspace inventory failed');
    }
    if (failed) throw StateError('Architecture fixture tests failed');
    stdout.writeln('${expected.length + 7} architecture checks passed');
  } finally {
    directory.deleteSync(recursive: true);
  }
}
