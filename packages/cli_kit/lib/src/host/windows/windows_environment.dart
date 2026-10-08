import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

@internal
final class WindowsEnvironment implements HostEnvironmentInterface {
  WindowsEnvironment(Map<String, String> values)
    : values = Map.unmodifiable(values);
  @override
  final Map<String, String> values;
  @override
  String? lookup(Map<String, String> environment, String key) {
    final exact = environment[key];
    if (exact != null) return exact;
    final normalized = key.toUpperCase();
    for (final entry in environment.entries) {
      if (entry.key.toUpperCase() == normalized) return entry.value;
    }
    return null;
  }

  @override
  Map<String, String> overlay(
    Map<String, String> base,
    Map<String, String> overrides,
  ) {
    final merged = {...base};
    for (final entry in overrides.entries) {
      merged.removeWhere(
        (key, _) => key.toUpperCase() == entry.key.toUpperCase(),
      );
      merged[entry.key] = entry.value;
    }
    return merged;
  }

  @override
  List<String> splitPathList(String value) => value.split(';');
  @override
  String joinPathList(Iterable<String> values) => values.join(';');
  @override
  List<String> executableCandidates(
    String name,
    Map<String, String> environment,
  ) {
    final extensions = (lookup(environment, 'PATHEXT') ?? '.COM;.EXE;.BAT;.CMD')
        .split(';')
        .where((extension) => extension.isNotEmpty)
        .map(
          (extension) => extension.startsWith('.') ? extension : '.$extension',
        )
        .toList();
    final lower = name.toLowerCase();
    if (extensions.any(
      (extension) => lower.endsWith(extension.toLowerCase()),
    )) {
      return [name];
    }
    return [name, for (final extension in extensions) '$name$extension'];
  }
}
