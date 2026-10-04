import 'package:meta/meta.dart';

/// The frontend_server snapshot and the Dart runtime able to execute it.
@immutable
final class KernelCompiler {
  const KernelCompiler({
    required this.snapshot,
    required this.runtime,
    required this.runtimeName,
    required this.isAot,
  });

  final String snapshot;
  final String runtime;
  final String runtimeName;
  final bool isAot;
}
