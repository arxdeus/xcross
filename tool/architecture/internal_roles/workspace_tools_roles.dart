import 'package:meta/meta.dart';

@internal
const workspaceToolsRoles = <String, Map<String, String>>{
  'workspace:packages/xcross/bin/xcross.dart': {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/bin/xcrun.dart': {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/tool/build_xcross.dart': {
    'FUNCTION:_buildCliExecutable': 'private',
    'FUNCTION:_core': 'private',
    'FUNCTION:_identitySource': 'private',
    'FUNCTION:_normalizeVersion': 'private',
    'FUNCTION:_pubspecVersion': 'private',
    'FUNCTION:_runBuild': 'private',
    'FUNCTION:_validateIdentity': 'private',
    'FUNCTION:buildXcross': 'internal',
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_encodedVersion': 'private',
    'TOP_LEVEL_VARIABLE:_released': 'private',
    'TYPE_ALIAS:BuildCliRun': 'internal',
  },
  'workspace:packages/xcross/tool/swiftpm_binary_fixture.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/tool/swiftpm_gate_evidence.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/tool/verify_flutter_notices.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:tool/architecture/acquisition_fixtures.dart': {
    'FUNCTION:acquisitionFixtures': 'internal',
  },
  'workspace:tool/architecture/boundaries.dart': {
    'CLASS:Classification': 'internal',
    'CLASS:Violation': 'internal',
    'TOP_LEVEL_VARIABLE:architectureSources': 'internal',
    'TOP_LEVEL_VARIABLE:ciFiles': 'internal',
    'TOP_LEVEL_VARIABLE:cliCompositions': 'internal',
    'TOP_LEVEL_VARIABLE:compositions': 'internal',
    'TOP_LEVEL_VARIABLE:detector': 'internal',
    'TOP_LEVEL_VARIABLE:detectorCallers': 'internal',
    'TOP_LEVEL_VARIABLE:entrypoints': 'internal',
    'TOP_LEVEL_VARIABLE:generatedCompositionParts': 'internal',
    'TOP_LEVEL_VARIABLE:hostAssemblies': 'internal',
    'TOP_LEVEL_VARIABLE:hostComposition': 'internal',
    'TOP_LEVEL_VARIABLE:hostFactories': 'internal',
    'TOP_LEVEL_VARIABLE:nativeHooks': 'internal',
    'TOP_LEVEL_VARIABLE:nativeSources': 'internal',
    'TOP_LEVEL_VARIABLE:partOwners': 'internal',
    'TOP_LEVEL_VARIABLE:resources': 'internal',
    'TOP_LEVEL_VARIABLE:standaloneAssemblies': 'internal',
    'TOP_LEVEL_VARIABLE:targetAssemblies': 'internal',
    'TOP_LEVEL_VARIABLE:targetComposition': 'internal',
    'TOP_LEVEL_VARIABLE:templates': 'internal',
    'TOP_LEVEL_VARIABLE:toolBoundaries': 'internal',
    'TOP_LEVEL_VARIABLE:workspacePackages': 'internal',
  },
  'workspace:tool/architecture/check.dart': {
    'FUNCTION:inspectFiles': 'internal',
    'FUNCTION:main': 'entrypoint',
    'FUNCTION:production': 'internal',
  },
  'workspace:tool/architecture/check_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:tool/architecture/declaration_fixtures.dart': {
    'FUNCTION:declarationFixtures': 'internal',
  },
  'workspace:tool/architecture/declarations.dart': {
    'CLASS:DeclarationRules': 'internal',
    'FUNCTION:sourcePolicyViolations': 'internal',
  },
  'workspace:tool/architecture/dependencies.dart': {
    'CLASS:DependencyRules': 'internal',
  },
  'workspace:tool/architecture/dependency_fixtures.dart': {
    'FUNCTION:dependencyAssets': 'internal',
    'FUNCTION:dependencyFixtures': 'internal',
    'FUNCTION:fixturePackageUri': 'internal',
  },
  'workspace:tool/architecture/dispatch_rules.dart': {
    'CLASS:DispatchRules': 'internal',
  },
  'workspace:tool/architecture/export_graph.dart': {
    'CLASS:ExportGraph': 'internal',
    'FUNCTION:resolveUri': 'internal',
    'FUNCTION:sourceFilePath': 'internal',
  },
  'workspace:tool/architecture/identity.dart': {
    'CLASS:IdentityAnalysis': 'internal',
    'FUNCTION:astNodes': 'internal',
  },
  'workspace:tool/architecture/internal_policy.dart': {
    'FUNCTION:canonicalLibraryUri': 'internal',
    'FUNCTION:declarationIdentities': 'internal',
    'FUNCTION:internalPolicyViolations': 'internal',
  },
  'workspace:tool/architecture/internal_roles.dart': {
    'TOP_LEVEL_VARIABLE:reviewedDeclarationRoles': 'internal',
    'TOP_LEVEL_VARIABLE:reviewedInternalLibraries': 'internal',
  },
  'workspace:tool/architecture/internal_roles/apple_developer_kit_roles.dart': {
    'TOP_LEVEL_VARIABLE:appleDeveloperKitRoles': 'internal',
  },
  'workspace:tool/architecture/internal_roles/apple_developer_kit_tests_roles.dart':
      {'TOP_LEVEL_VARIABLE:appleDeveloperKitTestsRoles': 'internal'},
  'workspace:tool/architecture/internal_roles/support_packages_roles.dart': {
    'TOP_LEVEL_VARIABLE:supportPackagesRoles': 'internal',
  },
  'workspace:tool/architecture/internal_roles/open_apple_macros_roles.dart': {
    'TOP_LEVEL_VARIABLE:openAppleMacrosRoles': 'internal',
  },
  'workspace:tool/architecture/internal_roles/workspace_tools_roles.dart': {
    'TOP_LEVEL_VARIABLE:workspaceToolsRoles': 'internal',
  },
  'workspace:tool/architecture/internal_roles/xcross_application_tests_roles.dart':
      {'TOP_LEVEL_VARIABLE:xcrossApplicationTestsRoles': 'internal'},
  'workspace:tool/architecture/internal_roles/xcross_compose_roles.dart': {
    'TOP_LEVEL_VARIABLE:xcrossComposeRoles': 'internal',
  },
  'workspace:tool/architecture/internal_roles/xcross_compose_tests_roles.dart':
      {'TOP_LEVEL_VARIABLE:xcrossComposeTestsRoles': 'internal'},
  'workspace:tool/architecture/internal_roles/xcross_flutter_roles.dart': {
    'TOP_LEVEL_VARIABLE:xcrossFlutterRoles': 'internal',
  },
  'workspace:tool/architecture/internal_roles/xcross_flutter_tests_roles.dart':
      {'TOP_LEVEL_VARIABLE:xcrossFlutterTestsRoles': 'internal'},
  'workspace:tool/architecture/internal_roles/xcross_platform_roles.dart': {
    'TOP_LEVEL_VARIABLE:xcrossPlatformRoles': 'internal',
  },
  'workspace:tool/architecture/internal_roles/xcross_shared_roles.dart': {
    'TOP_LEVEL_VARIABLE:xcrossSharedRoles': 'internal',
  },
  'workspace:tool/architecture/inventory.dart': {
    'FUNCTION:classify': 'internal',
    'FUNCTION:structuralPrimary': 'internal',
  },
  'workspace:tool/architecture/native_acquisition.dart': {
    'CLASS:NativeAcquisitionRules': 'internal',
  },
  'workspace:tool/architecture/native_rules.dart': {
    'CLASS:NativeRules': 'internal',
    'FUNCTION:topFunction': 'internal',
  },
  'workspace:tool/architecture/native_safety.dart': {
    'CLASS:NativeSafety': 'internal',
  },
  'workspace:tool/architecture/platform_fixtures.dart': {
    'FUNCTION:platformFixtures': 'internal',
  },
  'workspace:tool/architecture/rules.dart': {'CLASS:Guard': 'internal'},
  'workspace:tool/architecture/source_policy_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:tool/architecture/workspace_inventory.dart': {
    'FUNCTION:workspaceViolations': 'internal',
  },
};
