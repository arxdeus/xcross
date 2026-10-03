import 'dart:convert';
import 'inventory.dart';

List<Violation> workspaceViolations(String manifest, Iterable<String> files) {
  final violations = <Violation>[];
  final declared = <String>{};
  var reading = false;
  for (final line in const LineSplitter().convert(manifest)) {
    final value = line.trim();
    if (value.isEmpty || value.startsWith('#')) continue;
    if (!reading) {
      if (line == 'workspace:') reading = true;
      continue;
    }
    if (!line.startsWith(' ') && !line.startsWith('\t')) break;
    if (!value.startsWith('- ')) {
      violations.add(
        const Violation(
          'pubspec.yaml',
          'workspace-inventory',
          0,
          'Unsupported workspace declaration, cannot inventory safely',
        ),
      );
      continue;
    }
    var path = value.substring(2).trim();
    if (path.startsWith('"') && path.endsWith('"')) {
      path = jsonDecode(path) as String;
    }
    if (path.startsWith("'") && path.endsWith("'"))
      path = path.substring(1, path.length - 1).replaceAll("''", "'");
    if (!path.startsWith('packages/') ||
        path.split('/').length != 2 ||
        !workspacePackages.contains(path.split('/').last))
      violations.add(
        Violation(
          'pubspec.yaml',
          'workspace-inventory',
          0,
          'Unclassified declared workspace package: $path',
        ),
      );
    declared.add(path);
  }
  if (!reading)
    violations.add(
      const Violation(
        'pubspec.yaml',
        'workspace-inventory',
        0,
        'Missing explicit workspace package inventory',
      ),
    );
  for (final package in workspacePackages) {
    if (!declared.contains('packages/$package'))
      violations.add(
        Violation(
          'pubspec.yaml',
          'workspace-inventory',
          0,
          'Registry package missing from workspace: $package',
        ),
      );
  }
  final unknown = <String>{};
  for (final path in files) {
    final parts = path.split('/');
    if (parts.length >= 4 &&
        parts[0] == 'packages' &&
        {'lib', 'bin', 'hook', 'src', 'native', 'tool'}.contains(parts[2]) &&
        !workspacePackages.contains(parts[1]))
      unknown.add('packages/${parts[1]}');
    if (parts.length >= 2 &&
        {'lib', 'bin', 'hook', 'src', 'native'}.contains(parts[0]))
      unknown.add(parts[0]);
  }
  for (final path in unknown) {
    violations.add(
      Violation(
        path,
        'workspace-inventory',
        0,
        'Unregistered owned production root',
      ),
    );
  }
  return violations;
}
