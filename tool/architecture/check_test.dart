import 'dart:convert';
import 'dart:io';

import 'check.dart';
import 'workspace_inventory.dart';
import 'platform_fixtures.dart';
import 'declaration_fixtures.dart';
import 'dependency_fixtures.dart';

Future<void> main() async {
  final scratch =
      Platform.environment['JCODE_SCRATCH_DIR'] ?? Directory.systemTemp.path;
  final directory = Directory('$scratch/architecture-fixtures-$pid');
  directory.createSync(recursive: true);
  final config =
      jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
          as Map<String, dynamic>;
  final base = File('.dart_tool/package_config.json').absolute.uri;
  for (final package in config['packages'] as List<dynamic>) {
    package['rootUri'] = base.resolve(package['rootUri'] as String).toString();
  }
  final packageFile = File('${directory.path}/.dart_tool/package_config.json');
  packageFile.parent.createSync(recursive: true);
  packageFile.writeAsStringSync(jsonEncode(config));
  final cases = {
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
        classify('.github/FUNDING.yml').kind != 'ci-metadata')
      throw StateError('Exact CI axes failed');
    final manifest =
        'workspace:\n${workspacePackages.map((p) => '  - packages/$p').join('\n')}\n';
    if (workspaceViolations(manifest, []).isNotEmpty ||
        workspaceViolations(
          '$manifest  - packages/new_package\n',
          [],
        ).isEmpty ||
        workspaceViolations(manifest, ['packages/unknown/lib/a.dart']).isEmpty)
      throw StateError('Fail-closed workspace inventory failed');
    if (failed) throw StateError('Architecture fixture tests failed');
    stdout.writeln('${expected.length + 7} architecture checks passed');
  } finally {
    directory.deleteSync(recursive: true);
  }
}
