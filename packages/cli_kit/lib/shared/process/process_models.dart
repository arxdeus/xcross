import 'package:meta/meta.dart';

@immutable
final class CapturedProcess {
  const CapturedProcess(
    this.exitCode,
    this.stdout,
    this.stderr, {
    this.timedOut = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  final bool timedOut;
}

@immutable
final class ProcessConfiguration {
  ProcessConfiguration({
    required Map<String, String> normalizedTools,
    required Map<String, String> effectiveChildEnvironment,
    Map<String, List<String>> toolchainDirectories = const {},
  }) : normalizedTools = Map.unmodifiable(normalizedTools),
       toolchainDirectories = Map.unmodifiable({
         for (final entry in toolchainDirectories.entries)
           entry.key: List<String>.unmodifiable(entry.value),
       }),
       effectiveChildEnvironment = Map.unmodifiable(effectiveChildEnvironment);

  final Map<String, String> normalizedTools;
  final Map<String, List<String>> toolchainDirectories;
  final Map<String, String> effectiveChildEnvironment;
}
