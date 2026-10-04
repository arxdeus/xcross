import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'boundaries.dart';
import 'check.dart';
import 'declarations.dart';
import 'export_graph.dart';
import 'internal_policy.dart';
import 'inventory.dart';
import 'native_acquisition.dart';

Future<void> main(List<String> args) async {
  final root = args.single;
  var checked = 0;
  void expect({required bool condition, required String detail}) {
    checked++;
    if (!condition) throw StateError(detail);
  }

  const own = 'packages/xcross/lib/src/shared/policy_fixture.dart';
  List<Violation> policy(String source, {String path = own}) =>
      sourcePolicyViolations(
        path,
        parseString(content: source, throwIfDiagnostics: false).unit,
        root: root,
      );
  for (final source in [
    'class Contract {}',
    "// export 'other.dart';\n/* import 'x.dart' show Hidden; */\nconst text = \"export 'x.dart'; import 'x.dart' hide Hidden;\";",
    "const swift = \"import SwiftUI; export 'x.dart';\";\nconst shell = r\"export HOME; import 'x.dart' show Hidden;\";\nconst c = r\"#include <stdio.h>\";",
  ]) {
    expect(
      condition: policy(source).isEmpty,
      detail: 'Comment/string/native template false positive',
    );
  }
  for (final (source, rule, token) in [
    ("export 'missing.dart';", 'export-directive', 'export'),
    ("import 'missing.dart' show Missing;", 'show-combinator', 'show'),
    ("import 'missing.dart' hide Missing;", 'hide-combinator', 'hide'),
    (
      "export 'missing.dart' if (dart.library.io) 'other.dart';",
      'export-directive',
      'export',
    ),
  ]) {
    final findings = policy(source);
    expect(
      condition: findings.any(
        (v) => v.rule == rule && v.offset == source.indexOf(token),
      ),
      detail: 'Missing exact directive/combinator offset: $source',
    );
  }
  for (final uri in [
    'package:cli_kit/src/shared/platform/platform_host.dart',
    'package:cli_kit/shared/../src/shared/platform/platform_host.dart',
    '../../../../cli_kit/lib/src/shared/platform/platform_host.dart',
    Uri.file(
      '$root/packages/cli_kit/lib/src/shared/platform/platform_host.dart',
    ).toString(),
  ]) {
    expect(
      condition: policy(
        "import '$uri';",
      ).any((v) => v.rule == 'cross-package-src'),
      detail: 'Foreign implementation owner not canonicalized: $uri',
    );
  }
  for (final uri in [
    'package:xcross/src/shared/policy_fixture.dart',
    'package:cli_kit/shared/platform/platform_host.dart',
    Uri.file(
      '/external/packages/cli_kit/lib/src/shared/contract.dart',
    ).toString(),
  ]) {
    expect(
      condition: policy("import '$uri';").isEmpty,
      detail: 'Wrong canonical owner: $uri',
    );
  }
  expect(
    condition: policy(
      "import 'package:cli_kit/shared/platform/platform_host.dart' if (dart.library.io) 'package:cli_kit/src/shared/contract.dart';",
    ).any((v) => v.rule == 'cross-package-src'),
    detail: 'Conditional arm silently skipped',
  );
  for (final uri in [
    'package:cli_kit/../../src/contract.dart',
    'file://other.invalid/file.dart',
  ]) {
    expect(
      condition: policy("import '$uri';").any((v) => v.rule == 'source-uri'),
      detail: 'Invalid URI accepted',
    );
  }
  for (final path in [
    'packages/xcross/test/generated_fixture.g.dart',
    'packages/xcross/hook/generated_fixture.g.dart',
    'tool/architecture/generated_fixture.g.dart',
  ]) {
    expect(
      condition: policy(
        "export 'missing.dart';",
        path: path,
      ).any((v) => v.rule == 'export-directive'),
      detail: 'Generated/test/tool policy loophole: $path',
    );
    expect(
      condition: policy(
        'class _Generated {}',
        path: path,
      ).any((v) => v.rule == 'private-type'),
      detail: 'Private generated type loophole: $path',
    );
  }
  for (final path in [
    'packages/xcross/lib/shared/future.dart',
    'packages/xcross/lib/target/iphone/future.dart',
    'packages/xcross/lib/src/shared/future.dart',
    'packages/xcross/lib/src/target/iphone/future.dart',
  ]) {
    expect(
      condition: NativeAcquisitionRules(path).enabled,
      detail: 'Future shared/target acquisition disabled',
    );
    expect(
      condition: classify(path).kind == 'dart',
      detail: 'Future shared/target structural role lost',
    );
  }
  expect(
    condition: !NativeAcquisitionRules(
      'packages/xcross/lib/host/linux/future.dart',
    ).enabled,
    detail: 'Selected-host acquisition scope changed',
  );
  expect(
    condition:
        classify(
          'packages/xcross/lib/shared/src/host/windows/future.dart',
        ).host ==
        'shared',
    detail: 'Nested src segment reinterpreted as primary axis',
  );
  for (final path in [
    'packages/xcross/lib/composition/future.dart',
    'packages/xcross/lib/host/unknown/future.dart',
    'packages/xcross/lib/host/linux/target/unknown/future.dart',
  ]) {
    expect(
      condition: classify(path).kind == 'unclassified',
      detail: 'Unknown effect/axis path not fail closed',
    );
  }
  expect(
    condition:
        compositions.contains(
          'packages/apple_developer_kit/lib/composition/apple_host.dart',
        ) &&
        !compositions.contains(
          'packages/apple_developer_kit/lib/src/composition/apple_host.dart',
        ),
    detail: 'Composition permission retained old alias',
  );
  expect(
    condition:
        detector == 'packages/cli_kit/lib/composition/native_host.dart' &&
        !detectorCallers.containsKey(
          'packages/cli_kit/lib/src/composition/native_host.dart',
        ),
    detail: 'Detector permission retained old alias',
  );

  final directory = Directory('$root/.dart_tool/source-policy-fixtures-$pid');
  directory.createSync(recursive: true);
  try {
    final sourceConfig = File('$root/.dart_tool/package_config.json');
    final sourcePackages =
        jsonDecode(sourceConfig.readAsStringSync()) as Map<String, dynamic>;
    for (final package
        in (sourcePackages['packages'] as List).cast<Map<String, dynamic>>()) {
      package['rootUri'] = sourceConfig.uri
          .resolve(package['rootUri'] as String)
          .toString();
    }
    final packageConfig = jsonEncode(sourcePackages);
    final config = File('${directory.path}/.dart_tool/package_config.json');
    config.parent.createSync(recursive: true);
    config.writeAsStringSync(packageConfig);
    File(
      '${directory.path}/analysis_options.yaml',
    ).writeAsStringSync('analyzer:\n  exclude:\n    - "**/*.g.dart"\n');
    final cases = <String, (String, Set<String>)>{
      'packages/xcross/lib/shared/future.dart': (
        "import 'dart:io' as io; Object acquire(String path) => io.File(path);",
        {'native-acquisition'},
      ),
      'packages/xcross/lib/target/iphone/future.dart': (
        "import 'dart:io' as io; Future<Object> acquire() => io.Process.run('unused', []);",
        {'native-acquisition'},
      ),
      'packages/xcross/lib/shared/injected.dart': (
        'abstract class FilePort { Object file(String path); } Object acquire(FilePort files, String path) => files.file(path);',
        {},
      ),
      'packages/xcross/lib/host/linux/native.dart': (
        "import 'dart:io'; Object acquire(String path) => File(path);",
        {},
      ),
      'packages/xcross/test/excluded.g.dart': (
        "export 'missing.dart'; import 'missing.dart' show Missing; class _Private {}",
        {'export-directive', 'show-combinator', 'private-type'},
      ),
      'packages/xcross/test/malformed.dart': (
        "export 'missing.dart'; import 'missing.dart' hide Missing; class _Private {",
        {'export-directive', 'hide-combinator', 'source-parse', 'private-type'},
      ),
      'packages/xcross/lib/shared/nested.dart': (
        "import 'package:cli_kit/composition/native_host.dart'; Object other() { Object main() => detectPlatformHostSnapshot(); return main(); }",
        {'composition-edge', 'hidden-detection'},
      ),
      'packages/cli_kit/lib/src/composition/native_host.dart': (
        "import 'dart:io'; String detectPlatformHostSnapshot() => Platform.operatingSystem;",
        {'inventory', 'ambient-detection'},
      ),
      'packages/cli_kit/lib/composition/unrelated.dart': (
        "import 'dart:io'; String detectPlatformHostSnapshot() => Platform.operatingSystem;",
        {'inventory', 'ambient-detection'},
      ),
      'packages/xcross/test/detector_show.dart': (
        "import 'package:cli_kit/composition/native_host.dart' show detectPlatformHostSnapshot;",
        {'show-combinator'},
      ),
      'packages/xcross/lib/src/composition/cli/compose_build_command.g.dart': (
        "part of 'wrong_owner.dart'; class PublicParser {}",
        {'inventory'},
      ),
    };
    for (final entry in cases.entries) {
      final file = File('${directory.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value.$1);
    }
    final fixtureRoles = <String, Map<String, String>>{};
    for (final path in cases.keys) {
      if (!path.endsWith('.dart')) continue;
      final unit = parseString(
        content: File('${directory.path}/$path').readAsStringSync(),
        throwIfDiagnostics: false,
      ).unit;
      final part = unit.directives.whereType<PartOfDirective>().firstOrNull;
      final owner = part?.uri?.stringValue == null
          ? path
          : resolveUri(path, part!.uri!.stringValue!, root: directory.path);
      fixtureRoles
          .putIfAbsent(
            canonicalLibraryUri(owner, root: directory.path),
            () => {},
          )
          .addAll({
            for (final id in declarationIdentities(unit).keys) id: 'fixture',
          });
    }
    final violations = await inspectFiles(
      directory.path,
      cases.keys.toList(),
      declarationRoles: fixtureRoles,
      internalLibraries: {},
    );
    for (final entry in cases.entries) {
      final rules = violations
          .where((v) => v.path == entry.key)
          .map((v) => v.rule)
          .toSet();
      expect(
        condition: rules.containsAll(entry.value.$2),
        detail: '${entry.key}: expected ${entry.value.$2}, actual $rules',
      );
      if (entry.value.$2.isEmpty) {
        expect(
          condition: rules.isEmpty,
          detail: '${entry.key}: unexpected $rules',
        );
      }
    }
    final showSource = cases['packages/xcross/test/detector_show.dart']!.$1;
    expect(
      condition: violations.any(
        (v) =>
            v.path.endsWith('/detector_show.dart') &&
            v.rule == 'show-combinator' &&
            v.offset == showSource.indexOf('show'),
      ),
      detail: 'Resolved show node offset lost',
    );
    expect(
      condition: !violations.any(
        (v) =>
            v.path.endsWith('/detector_show.dart') &&
            v.rule == 'hidden-detection',
      ),
      detail: 'Combinator identifier interpreted as detector call',
    );
    const direct = 'packages/cli_kit/lib/shared/direct_internal_fixture.dart';
    const libraryPath =
        'packages/cli_kit/lib/shared/library_internal_fixture.dart';
    const directUri = 'package:cli_kit/shared/direct_internal_fixture.dart';
    const libraryUri = 'package:cli_kit/shared/library_internal_fixture.dart';
    const anonymousPath =
        'packages/cli_kit/lib/src/shared/anonymous_extension_fixture.dart';
    const anonymousUri =
        'package:cli_kit/src/shared/anonymous_extension_fixture.dart';
    const anonymousSource =
        'extension on String {}\nextension on int {}\nextension Named on bool {}';
    const anonymousIds = {'EXTENSION:@0', 'EXTENSION:@23', 'EXTENSION:Named'};
    final parsedAnonymousIds = declarationIdentities(
      parseString(content: anonymousSource).unit,
    ).keys.toSet();
    expect(
      condition:
          parsedAnonymousIds.length == 3 &&
          parsedAnonymousIds.containsAll(anonymousIds),
      detail: 'Parsed anonymous extensions collapsed or named identity changed',
    );
    final annotated = <String, String>{
      anonymousPath: anonymousSource,
      direct: "import 'package:meta/meta.dart'; @internal class HiddenModel {}",
      libraryPath:
          "@internal library; import 'package:meta/meta.dart'; part 'library_internal_fixture.g.dart';",
      'packages/cli_kit/lib/shared/library_internal_fixture.g.dart':
          "part of 'library_internal_fixture.dart'; int generatedParser() => 1;",
      'packages/cli_kit/lib/shared/same_package_fixture.dart':
          "import '$directUri'; import '$libraryUri'; HiddenModel? value; int parser() => generatedParser();",
      'packages/xcross/lib/shared/foreign_package_fixture.dart':
          "import '$directUri'; import '$libraryUri'; HiddenModel? value; int parser() => generatedParser();",
      'packages/cli_kit/lib/shared/missing_internal_fixture.dart':
          'class UnannotatedModel {}',
      'packages/cli_kit/lib/shared/fake_internal_fixture.dart':
          'class Annotation { const Annotation(); } const internal = Annotation(); @internal class FakeModel {}',
      'packages/cli_kit/lib/shared/public_internal_fixture.dart':
          "import 'package:meta/meta.dart'; @internal class PublicModel {}",
      'packages/cli_kit/lib/shared/unknown_role_fixture.dart':
          'class UnknownModel {}',
    };
    final annotationRoles = <String, Map<String, String>>{};
    for (final entry in annotated.entries) {
      final file = File('${directory.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
      final unit = parseString(
        content: entry.value,
        throwIfDiagnostics: false,
      ).unit;
      final part = unit.directives.whereType<PartOfDirective>().firstOrNull;
      final owner = part?.uri?.stringValue == null
          ? entry.key
          : resolveUri(entry.key, part!.uri!.stringValue!);
      annotationRoles
          .putIfAbsent(
            canonicalLibraryUri(owner, root: directory.path),
            () => {},
          )
          .addAll({
            for (final id in declarationIdentities(unit).keys) id: 'fixture',
          });
    }
    annotationRoles[canonicalLibraryUri(direct)]!['CLASS:HiddenModel'] =
        'internal';
    annotationRoles[canonicalLibraryUri(
          libraryPath,
        )]!['FUNCTION:generatedParser'] =
        'library-internal';
    annotationRoles['package:cli_kit/shared/missing_internal_fixture.dart']!['CLASS:UnannotatedModel'] =
        'internal';
    annotationRoles['package:cli_kit/shared/fake_internal_fixture.dart']!['CLASS:FakeModel'] =
        'internal';
    annotationRoles['package:cli_kit/shared/public_internal_fixture.dart']!['CLASS:PublicModel'] =
        'public';
    annotationRoles.remove('package:cli_kit/shared/unknown_role_fixture.dart');
    annotationRoles[anonymousUri] = {
      'EXTENSION:@0': 'private',
      'EXTENSION:@23': 'private',
      'EXTENSION:Named': 'fixture',
    };
    final expectedAnnotationRules = <String, Set<String>>{
      anonymousPath: {},
      direct: {},
      libraryPath: {},
      'packages/cli_kit/lib/shared/library_internal_fixture.g.dart': {},
      'packages/cli_kit/lib/shared/same_package_fixture.dart': {},
      'packages/xcross/lib/shared/foreign_package_fixture.dart': {
        'internal-use',
        'internal-library-use',
      },
      'packages/cli_kit/lib/shared/missing_internal_fixture.dart': {
        'internal-annotation',
      },
      'packages/cli_kit/lib/shared/fake_internal_fixture.dart': {
        'internal-annotation',
      },
      'packages/cli_kit/lib/shared/public_internal_fixture.dart': {
        'public-internal',
      },
      'packages/cli_kit/lib/shared/unknown_role_fixture.dart': {
        'annotation-role',
      },
    };
    final annotationConfig = jsonDecode(packageConfig) as Map<String, dynamic>;
    for (final package
        in (annotationConfig['packages'] as List)
            .cast<Map<String, dynamic>>()) {
      if (package['name'] == 'cli_kit' || package['name'] == 'xcross') {
        package['rootUri'] = Uri.directory(
          '${directory.path}/packages/${package['name']}',
        ).toString();
        File(
          '${directory.path}/packages/${package['name']}/pubspec.yaml',
        ).writeAsStringSync(
          "name: ${package['name']}\nenvironment:\n  sdk: ^3.10.0\ndependencies:\n  meta: ^1.19.0\n",
        );
      }
    }
    config.writeAsStringSync(jsonEncode(annotationConfig));
    final collection = AnalysisContextCollection(
      includedPaths: [directory.path],
    );
    try {
      for (final path in annotated.keys) {
        final absolute = '${directory.path}/$path';
        final contexts =
            collection.contexts
                .where(
                  (c) => absolute.startsWith('${c.contextRoot.root.path}/'),
                )
                .toList()
              ..sort(
                (a, b) => b.contextRoot.root.path.length.compareTo(
                  a.contextRoot.root.path.length,
                ),
              );
        final result = await contexts.first.currentSession.getResolvedUnit(
          absolute,
        );
        expect(
          condition: result is ResolvedUnitResult,
          detail: 'Annotation fixture failed resolution: $path',
        );
        final resolved = result as ResolvedUnitResult;
        final rules = internalPolicyViolations(
          path,
          resolved.unit,
          root: directory.path,
          roles: annotationRoles,
          internalLibraries: {canonicalLibraryUri(libraryPath)},
        ).map((v) => v.rule).toSet();
        expect(
          condition:
              rules.length == expectedAnnotationRules[path]!.length &&
              rules.containsAll(expectedAnnotationRules[path]!),
          detail:
              '$path annotation expected ${expectedAnnotationRules[path]}, actual $rules',
        );
        final invalidUse = resolved.diagnostics
            .where(
              (e) => e.diagnosticCode.lowerCaseName.contains(
                'invalid_use_of_internal',
              ),
            )
            .toList();
        if (path == anonymousPath) {
          final ids = declarationIdentities(resolved.unit).keys.toSet();
          expect(
            condition: ids.length == 3 && ids.containsAll(anonymousIds),
            detail:
                'Resolved anonymous extensions collapsed or named identity changed',
          );
          final collectorIds = resolved.unit.declarations
              .whereType<ExtensionDeclaration>()
              .map(
                (node) =>
                    'EXTENSION:${node.declaredFragment!.element.name ?? '@${node.declaredFragment!.element.firstFragment.offset}'}',
              )
              .toSet();
          expect(
            condition:
                collectorIds.length == ids.length &&
                collectorIds.containsAll(ids),
            detail:
                'Anonymous identities disagree with actual canonical collector',
          );
          for (final missing in {
            'EXTENSION:@0': 0,
            'EXTENSION:@23': 23,
          }.entries) {
            final roles = {
              anonymousUri: {...annotationRoles[anonymousUri]!}
                ..remove(missing.key),
            };
            final rejected = internalPolicyViolations(
              path,
              resolved.unit,
              root: directory.path,
              roles: roles,
              internalLibraries: {},
            ).where((node) => node.rule == 'annotation-role').toList();
            expect(
              condition:
                  rejected.length == 1 &&
                  rejected.single.offset == missing.value &&
                  rejected.single.detail.contains(missing.key),
              detail:
                  'Missing exact anonymous role was not rejected independently: ${missing.key}',
            );
          }
          expect(
            condition: resolved.diagnostics.isEmpty,
            detail: 'Anonymous identity pair has analyzer diagnostics',
          );
        }
        if (path.endsWith('/same_package_fixture.dart')) {
          expect(
            condition: invalidUse.isEmpty,
            detail: 'Same-package internal use rejected by analyzer',
          );
        }
        if (path.endsWith('/foreign_package_fixture.dart')) {
          expect(
            condition: invalidUse.isNotEmpty,
            detail: 'Analyzer did not reject foreign package internal use',
          );
        }
        if (path.endsWith('library_internal_fixture.g.dart')) {
          final element = declarationIdentities(
            resolved.unit,
          )['FUNCTION:generatedParser']!.$2!;
          expect(
            condition:
                !element.metadata.hasInternal &&
                element.library!.metadata.hasInternal,
            detail:
                'Generated direct metadata was faked or owning library metadata lost',
          );
        }
      }
    } finally {
      await collection.dispose();
    }
  } finally {
    directory.deleteSync(recursive: true);
  }
  print('$checked source policy checks passed');
}
