import 'package:meta/meta.dart';

@internal
abstract interface class SwiftPmHostPolicy {
  String artifactIdentity(String value);
  List<String> get packagePrefix;
  List<String> get buildPrefix;
  String get packageTool;
  String get buildTool;
  List<String> get manifestArguments;
  List<String> get buildArguments;
  List<String> get linkerArguments;
  List<String> get fingerprintArguments;
  List<String> get gitConfiguration;
  Map<String, String> get sourceEnvironment;
  Future<Map<String, String>> hostEnvironment();

  Future<bool> repairBuildPlan(String scratchPath, String targetBuildDir);

  List<String> orderInteropTargets(
    Map<String, dynamic>? dependencies,
    List<String> targets,
  );
  List<String> selectInteropTargets(
    List<String> planned,
    Set<String> candidates,
  );

  bool get captureBuildOutput;

  Map<String, String> bundledToolEnvironment(
    String executable,
    Map<String, String> environment,
  );
  List<String> linkerPathArguments(String path);
}
