import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// Per-project xcross settings, committed alongside the project.
///
/// Read from `xcross_project.yaml` when it exists, otherwise from the `xcross:`
/// section of `pubspec.yaml`. Writes go to the same place, and a project with
/// neither (a Compose app, say) gets a new `xcross_project.yaml`. Edits keep
/// the rest of the file, comments included, as it was.
@internal
final class ProjectSettings {
  ProjectSettings({required this.fileSystem, required this.projectRoot});

  static const projectFileName = 'xcross_project.yaml';
  static const pubspecFileName = 'pubspec.yaml';
  static const pubspecSection = 'xcross';

  final HostFileSystemInterface fileSystem;
  final String projectRoot;

  String get _projectFile => p.join(projectRoot, projectFileName);
  String get _pubspecFile => p.join(projectRoot, pubspecFileName);

  /// Where settings live: the file plus the key path to the settings map.
  (String, List<String>) get _location {
    if (fileSystem.file(_projectFile).existsSync()) return (_projectFile, []);
    if (fileSystem.file(_pubspecFile).existsSync()) {
      return (_pubspecFile, [pubspecSection]);
    }
    return (_projectFile, []);
  }

  /// Display path of the file settings are read from and written to.
  String get path => _location.$1;

  String? read(String key) {
    final (path, section) = _location;
    final file = fileSystem.file(path);
    if (!file.existsSync()) return null;
    Object? node;
    try {
      node = loadYaml(file.readAsStringSync());
    } on YamlException catch (error) {
      throw XcrossError('$path: invalid YAML: ${error.message}');
    }
    for (final segment in [...section, key]) {
      if (node is! Map) return null;
      node = node[segment];
    }
    if (node == null) return null;
    if (node is! String) {
      throw XcrossError(
        '$path: ${[...section, key].join('.')} must be a string.',
      );
    }
    return node;
  }

  Future<void> write(String key, String value) async {
    final (path, section) = _location;
    final file = fileSystem.file(path);
    final source = file.existsSync() ? await file.readAsString() : '';
    if (source.trim().isEmpty) {
      final lines = [
        for (final (i, segment) in section.indexed) '${'  ' * i}$segment:',
        '${'  ' * section.length}$key: ${_scalar(value)}',
      ];
      await file.writeAsString('${lines.join('\n')}\n', flush: true);
      return;
    }
    final editor = YamlEditor(source);
    // Create the first missing section with the value already inside it, in
    // one update, so yaml_edit renders it in the document's block style.
    var depth = 0;
    while (depth < section.length &&
        editor
                .parseAt(
                  section.sublist(0, depth + 1),
                  orElse: () => wrapAsYamlNode(null),
                )
                .value
            is Map) {
      depth++;
    }
    if (depth == section.length) {
      editor.update([...section, key], value);
    } else {
      Object node = {key: value};
      for (final segment in section.sublist(depth + 1).reversed) {
        node = {segment: node};
      }
      editor.update(section.sublist(0, depth + 1), node);
    }
    var output = editor.toString();
    if (!output.endsWith('\n')) output = '$output\n';
    await file.writeAsString(output, flush: true);
  }

  static String _scalar(String value) =>
      RegExp(r'^[A-Za-z0-9_.\-]+$').hasMatch(value) ? value : '"$value"';
}
