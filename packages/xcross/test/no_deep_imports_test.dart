import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final String _repoRoot = Directory.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:xcross/'))!,
).parent.parent.parent.path;

const _packages = {
  'xcross',
  'cli_kit',
  'apple_developer_kit',
  'darwin_sdk_kit',
  'dart_mobile_device',
  'frontend_server_kit',
};

@internal
List<String> deepImportViolations(String root, Iterable<String> paths) {
  final result = <String>[];
  final rootUri = Uri.directory(root).normalizePath();
  String? owner(String path) {
    final parts = path.split('/');
    return parts.length > 2 &&
            parts[0] == 'packages' &&
            _packages.contains(parts[1])
        ? parts[1]
        : null;
  }

  for (final path in paths) {
    if (!path.endsWith('.dart') || owner(path) == null) continue;
    final parsed = parseString(
      content: File('$root/$path').readAsStringSync(),
      path: '$root/$path',
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) result.add('$path: cannot parse Dart source');
    for (final directive in parsed.unit.directives) {
      final literals = <StringLiteral>[];
      if (directive is UriBasedDirective) literals.add(directive.uri);
      if (directive is NamespaceDirective) {
        literals.addAll(directive.configurations.map((c) => c.uri));
      }
      if (directive is PartOfDirective && directive.uri != null) {
        literals.add(directive.uri!);
      }
      for (final literal in literals) {
        final text = literal.stringValue;
        final uri = text == null ? null : Uri.tryParse(text);
        if (uri == null || uri.hasQuery || uri.hasFragment) {
          result.add('$path:${literal.offset}: invalid source URI');
          continue;
        }
        String destination;
        if (uri.scheme == 'package') {
          final parts = uri.path.split('/');
          if (parts.length < 2 || parts.first.isEmpty) {
            result.add('$path:${literal.offset}: invalid package URI');
            continue;
          }
          final packageRoot = 'packages/${parts.first}/lib/';
          destination = Uri.parse(
            packageRoot,
          ).resolve(parts.skip(1).join('/')).normalizePath().path;
          if (!destination.startsWith(packageRoot)) {
            result.add('$path:${literal.offset}: package URI escapes library');
            continue;
          }
        } else if (uri.scheme == 'file') {
          if (uri.host.isNotEmpty && uri.host != 'localhost') {
            result.add('$path:${literal.offset}: invalid file URI');
            continue;
          }
          final absolute = uri.normalizePath().path;
          destination = absolute.startsWith(rootUri.path)
              ? absolute.substring(rootUri.path.length)
              : absolute;
        } else if (!uri.hasScheme &&
            !uri.hasAuthority &&
            !uri.path.startsWith('/')) {
          destination = Uri.parse(path).resolveUri(uri).normalizePath().path;
          if (destination.startsWith('../')) {
            result.add('$path:${literal.offset}: source URI escapes workspace');
            continue;
          }
        } else {
          continue;
        }
        final destinationOwner = owner(destination);
        if (destinationOwner != null &&
            destinationOwner != owner(path) &&
            destination.startsWith('packages/$destinationOwner/lib/src/')) {
          result.add('$path:${literal.offset}: cross-package src $destination');
        }
      }
    }
  }
  return result;
}

void main() {
  test('package-directory locator survives deleted barrel', () {
    expect(Directory('$_repoRoot/packages/xcross/lib').existsSync(), isTrue);
    expect(
      Isolate.resolvePackageUriSync(Uri.parse('package:xcross/')),
      Directory('$_repoRoot/packages/xcross/lib').uri,
    );
  });

  test('no cross-package src imports outside owning package', () async {
    final repository = await Process.run('git', [
      'rev-parse',
      '--show-toplevel',
    ], workingDirectory: _repoRoot);
    // git prints forward slashes on Windows, so compare canonical paths.
    if (repository.exitCode != 0 ||
        !p.equals((repository.stdout as String).trim(), _repoRoot)) {
      throw StateError(
        'Owned source inventory requires the exact repository root',
      );
    }
    final inventory = await Process.run('git', [
      'ls-files',
      '-z',
      '--cached',
      '--others',
      '--exclude-standard',
    ], workingDirectory: _repoRoot);
    if (inventory.exitCode != 0) {
      throw StateError('Cannot inventory owned sources');
    }
    final paths = (inventory.stdout as String)
        .split('\u0000')
        .where((path) => File('$_repoRoot/$path').existsSync());
    final violations = deepImportViolations(_repoRoot, paths);
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
