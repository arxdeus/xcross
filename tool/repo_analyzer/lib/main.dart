import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'package:repo_analyzer/src/rule_base.dart';
import 'package:repo_analyzer/src/rules/declaration_rules.dart';
import 'package:repo_analyzer/src/rules/dependency_rules.dart';
import 'package:repo_analyzer/src/rules/native_access_rules.dart';
import 'package:repo_analyzer/src/rules/platform_dispatch_rules.dart';
import 'package:repo_analyzer/src/rules/platform_rules.dart';

/// Entry point loaded by the Dart analysis server.
final plugin = RepoAnalyzerPlugin();

/// Every architecture rule, in reporting order.
List<ArchitectureRule> architectureRules() => [
  // Platform composition.
  PlatformBranchRule(),
  PlatformIdentityBoolRule(),
  PlatformRegistryRule(),
  PlatformVisitorRule(),
  PlatformCallbackDispatchRule(),
  AmbientPlatformStateRule(),
  HiddenPlatformDetectionRule(),
  NativeAcquisitionRule(),
  // Layering.
  CompositionEdgeRule(),
  ConcretePlatformEdgeRule(),
  LibraryLayoutRule(),
  ThinEntrypointRule(),
  // Declarations and dependency injection.
  PrivateTypeRule(),
  DirectImportRule(),
  MissingInternalRule(),
  GlobalServiceRule(),
  HiddenDependencyRule(),
  AmbientNetworkRule(),
  TargetHostBoundRule(),
];

/// The xcross workspace architecture plugin.
///
/// All rules are registered as warnings so they are enabled by default once
/// the plugin is listed under `plugins:` in `analysis_options.yaml`.
final class RepoAnalyzerPlugin extends Plugin {
  @override
  String get name => 'repo_analyzer';

  @override
  void register(PluginRegistry registry) {
    for (final rule in architectureRules()) {
      registry.registerWarningRule(rule);
    }
  }
}
