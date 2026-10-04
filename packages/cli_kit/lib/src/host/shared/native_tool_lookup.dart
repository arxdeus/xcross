import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

@internal
String? locateNativeCleanupTool(
  String name, {
  required HostPathsInterface paths,
  required HostEnvironmentInterface environment,
  required HostFileSystemInterface fileSystem,
  Map<String, String>? childEnvironment,
  Map<String, String> executableOverrides = const {},
}) {
  final override = executableOverrides[name];
  if (override != null) return override;
  final values = childEnvironment ?? environment.values;
  final directories = environment.splitPathList(
    environment.lookup(values, 'PATH') ?? '',
  );
  final candidates = environment.executableCandidates(name, values);
  for (final directory in directories) {
    if (directory.isEmpty) continue;
    for (final candidate in candidates) {
      final path = paths.context.join(directory, candidate);
      if (fileSystem.file(path).existsSync()) return path;
    }
  }
  return null;
}
