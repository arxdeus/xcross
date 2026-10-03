import 'package:cli_kit/src/shared/platform/platform_host.dart';

final class PosixEnvironment implements HostEnvironmentInterface {
  PosixEnvironment(Map<String, String> values)
    : values = Map.unmodifiable(values);
  @override
  final Map<String, String> values;
  @override
  String? lookup(Map<String, String> environment, String key) =>
      environment[key];
  @override
  Map<String, String> overlay(
    Map<String, String> base,
    Map<String, String> overrides,
  ) => {...base, ...overrides};
  @override
  List<String> splitPathList(String value) => value.split(':');
  @override
  String joinPathList(Iterable<String> values) => values.join(':');
  @override
  List<String> executableCandidates(
    String name,
    Map<String, String> environment,
  ) => [name];
}
