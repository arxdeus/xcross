import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/config/config.dart';
import 'package:xcross/src/shared/config/config_host.dart';

/// Discovers, loads, and atomically stores xcross configuration files.
final class XcrossConfigStore<T extends PlatformHostInterface> {
  XcrossConfigStore(
    this.host, {
    required this.policy,
    this.directory,
    Map<String, String>? environment,
  }) : environment = Map.unmodifiable(environment ?? host.environment.values);

  static const selectorVariable = 'XCROSS_CONFIG';
  static const preferredName = 'config.yaml';
  static const fallbackName = 'config.yml';

  final T host;
  final String? directory;
  final Map<String, String> environment;
  final ConfigHostInterface policy;

  String get defaultDirectory =>
      directory ?? host.paths.context.join(host.paths.configRoot, 'xcross');

  File? selectedFile() {
    final selector = host.environment
        .lookup(environment, selectorVariable)
        ?.trim();
    if (selector != null && selector.isNotEmpty) {
      return host.fileSystem.file(selector);
    }
    final yaml = host.fileSystem.file(
      host.paths.context.join(defaultDirectory, preferredName),
    );
    if (yaml.existsSync()) return yaml;
    final yml = host.fileSystem.file(
      host.paths.context.join(defaultDirectory, fallbackName),
    );
    return yml.existsSync() ? yml : null;
  }

  Future<XcrossConfig?> load() async {
    final file = selectedFile();
    if (file == null) return null;
    if (!file.existsSync()) {
      throw XcrossConfigException(
        'Selected configuration does not exist',
        path: file.path,
      );
    }
    try {
      return XcrossConfig.parse(
        await file.readAsString(),
        sourcePath: file.path,
        environment: environment,
        host: host,
        policy: policy,
      );
    } on FileSystemException catch (error) {
      throw XcrossConfigException(error.message, path: file.path);
    }
  }

  Future<File> save(XcrossConfig config, {String? path}) async {
    final selected = host.environment
        .lookup(environment, selectorVariable)
        ?.trim();
    final target = host.fileSystem.file(
      path ??
          (selected != null && selected.isNotEmpty
              ? selected
              : selectedFile()?.path ??
                    host.paths.context.join(defaultDirectory, preferredName)),
    );
    await target.parent.create(recursive: true);
    final temporary = host.fileSystem.file(
      '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(config.toYaml(), flush: true);
      await policy.replace(temporary, target);
    } finally {
      if (temporary.existsSync()) await temporary.delete();
    }
    return target;
  }
}
