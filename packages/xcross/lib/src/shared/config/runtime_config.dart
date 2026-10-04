import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/config/config.dart';
import 'package:xcross/src/shared/config/config_host.dart';
import 'package:xcross/src/shared/config/config_store.dart';

@internal
final class XcrossRuntimeConfig {
  XcrossRuntimeConfig({
    required this.config,
    required this.configPath,
    required Map<String, String> processEnvironment,
    required Map<String, String> childEnvironment,
  }) : processEnvironment = Map.unmodifiable(processEnvironment),
       childEnvironment = Map.unmodifiable(childEnvironment);

  final XcrossConfig? config;
  final String? configPath;
  final Map<String, String> processEnvironment;
  final Map<String, String> childEnvironment;

  bool get isLegacy => config == null;
  bool get isConfigured => config != null;
  XcrossConfigRoots? get roots => config?.roots;
  Map<String, String> get tools => config?.tools ?? const {};
  String? tool(String name) => config?.tool(name);
  Map<String, Object> get environment =>
      config?.environment ?? processEnvironment;

  ProcessConfiguration? get processConfiguration {
    final value = config;
    if (value == null) return null;
    return ProcessConfiguration(
      normalizedTools: value.tools,
      toolchainDirectories: {
        if (value.toolchains.swift case final swift?) 'swift': [swift],
        if (value.toolchains.llvm.isNotEmpty) 'llvm': value.toolchains.llvm,
      },
      effectiveChildEnvironment: childEnvironment,
    );
  }

  static Future<XcrossRuntimeConfig> load<T extends PlatformHostInterface>(
    T host, {
    required ConfigHostInterface policy,
    XcrossConfigStore<T>? store,
    String? configDirectory,
  }) async {
    final selectedStore =
        store ??
        XcrossConfigStore(host, directory: configDirectory, policy: policy);
    final selected = selectedStore.selectedFile();
    final config = await selectedStore.load();
    final inherited = host.environment.values;
    final overrides = <String, String>{};
    if (config != null) {
      for (final entry in config.environment.entries) {
        overrides[entry.key] = switch (entry.value) {
          final String value => value,
          final List<String> paths => host.environment.joinPathList([
            ...paths,
            if (host.environment.lookup(inherited, entry.key)
                case final existing?)
              existing,
          ]),
          _ => throw StateError('Unsupported environment value: ${entry.key}'),
        };
      }
      if (config.roots.javaHome case final javaHome?) {
        overrides['JAVA_HOME'] = javaHome;
      }
      if (config.roots.konanData case final konanData?) {
        overrides['KONAN_DATA_DIR'] = konanData;
      }
      if (selected case final file?) {
        overrides[XcrossConfigStore.selectorVariable] = file.path;
      }
    }
    return XcrossRuntimeConfig(
      config: config,
      configPath: selected?.path,
      processEnvironment: inherited,
      childEnvironment: host.environment.overlay(inherited, overrides),
    );
  }
}
