import 'package:meta/meta.dart';

@internal
const xcrossFlutterRoles = <String, Map<String, String>>{
  'package:xcross/src/shared/flutter/build/adhoc_signature_refresher.dart': {
    'CLASS:AdHocSignatureRefresher': 'internal',
  },
  'package:xcross/src/shared/flutter/build/app_extension_builder.dart': {
    'CLASS:AppExtensionBuilder': 'internal',
    'CLASS:BuiltAppExtension': 'internal',
  },
  'package:xcross/src/shared/flutter/build/dart_plugin_registrant.dart': {
    'CLASS:DartPluginRegistrant': 'internal',
    'CLASS:DartPluginRegistration': 'internal',
  },
  'package:xcross/src/shared/flutter/build/flutter_debug_bundler.dart': {
    'CLASS:FlutterDebugBundler': 'internal',
  },
  'package:xcross/src/shared/flutter/build/flutter_notice_artifact.dart': {
    'CLASS:FlutterNoticeArtifact': 'internal',
  },
  'package:xcross/src/shared/flutter/build/flutter_pack_operation.dart': {
    'CLASS:FlutterPackOperation': 'internal',
  },
  'package:xcross/src/shared/flutter/build/flutter_packer.dart': {
    'CLASS:FlutterPacker': 'internal',
  },
  'package:xcross/src/shared/flutter/build/hot_reload_setup.dart': {
    'CLASS:HotReloadSetup': 'internal',
  },
  'package:xcross/src/shared/flutter/build/info_plist.dart': {
    'CLASS:InfoPlist': 'internal',
  },
  'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart': {
    'CLASS:AppleToolShimConfig': 'internal',
    'CLASS:AppleToolShimResolver': 'internal',
    'CLASS:OtoolConfig': 'internal',
    'FUNCTION:installAppleToolShims': 'internal',
  },
  'package:xcross/src/shared/flutter/build/internal/flutter_tool_workspace.dart':
      {'CLASS:FlutterToolWorkspace': 'internal'},
  'package:xcross/src/shared/flutter/build/internal/kernel_compiler.dart': {
    'CLASS:KernelCompiler': 'internal',
  },
  'package:xcross/src/shared/flutter/build/internal/native_asset_frameworks.dart':
      {
        'CLASS:NativeAssetFrameworks': 'internal',
        'TOP_LEVEL_VARIABLE:_fatMachOMagics': 'private',
      },
  'package:xcross/src/shared/flutter/build/internal/native_asset_linkage.dart':
      {
        'CLASS:ExportTrieReader': 'internal',
        'CLASS:NativeAssetLinkage': 'internal',
        'FUNCTION:_isDefinedPublicSymbol': 'private',
        'FUNCTION:_isUnboundOrdinal': 'private',
        'FUNCTION:_isUndefinedPublicSymbol': 'private',
        'FUNCTION:_lazySymbolTableEntries': 'private',
        'FUNCTION:_readExportTrieAt': 'private',
        'FUNCTION:_symbolTableEntries': 'private',
        'TOP_LEVEL_VARIABLE:_absolute': 'private',
        'TOP_LEVEL_VARIABLE:_dyldInfo': 'private',
        'TOP_LEVEL_VARIABLE:_dyldInfoExportOffset': 'private',
        'TOP_LEVEL_VARIABLE:_dyldInfoMinimumSize': 'private',
        'TOP_LEVEL_VARIABLE:_dyldInfoOnly': 'private',
        'TOP_LEVEL_VARIABLE:_dynamicLookupOrdinal': 'private',
        'TOP_LEVEL_VARIABLE:_executableOrdinal': 'private',
        'TOP_LEVEL_VARIABLE:_exportsTrie': 'private',
        'TOP_LEVEL_VARIABLE:_external': 'private',
        'TOP_LEVEL_VARIABLE:_forceFlatNamespace': 'private',
        'TOP_LEVEL_VARIABLE:_headerFlagsOffset': 'private',
        'TOP_LEVEL_VARIABLE:_indirect': 'private',
        'TOP_LEVEL_VARIABLE:_libraryOrdinalShift': 'private',
        'TOP_LEVEL_VARIABLE:_linkeditDataMinimumSize': 'private',
        'TOP_LEVEL_VARIABLE:_linkeditDataOffset': 'private',
        'TOP_LEVEL_VARIABLE:_nlistDescriptionOffset': 'private',
        'TOP_LEVEL_VARIABLE:_nlistSize': 'private',
        'TOP_LEVEL_VARIABLE:_privateExternal': 'private',
        'TOP_LEVEL_VARIABLE:_section': 'private',
        'TOP_LEVEL_VARIABLE:_stab': 'private',
        'TOP_LEVEL_VARIABLE:_symbolType': 'private',
        'TOP_LEVEL_VARIABLE:_twoLevelNamespace': 'private',
        'TOP_LEVEL_VARIABLE:_ulebContinuation': 'private',
        'TOP_LEVEL_VARIABLE:_ulebMaximumShift': 'private',
        'TOP_LEVEL_VARIABLE:_ulebPayloadMask': 'private',
        'TOP_LEVEL_VARIABLE:_undefined': 'private',
        'TOP_LEVEL_VARIABLE:_weakReference': 'private',
        'TYPE_ALIAS:NativeSymbolEntry': 'internal',
      },
  'package:xcross/src/shared/flutter/build/internal/native_assets_hook_discovery.dart':
      {'CLASS:NativeAssetsHookDiscovery': 'internal'},
  'package:xcross/src/shared/flutter/build/internal/native_assets_manifest.dart':
      {'FUNCTION:normalizeIosNativeAssetsManifest': 'internal'},
  'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart':
      {'CLASS:RecursiveDirectoryCopier': 'internal'},
  'package:xcross/src/shared/flutter/build/internal/required_plist_key.dart': {
    'CLASS:RequiredPlistKey': 'internal',
  },
  'package:xcross/src/shared/flutter/build/internal/runner_binary.dart': {
    'CLASS:RunnerBinary': 'internal',
  },
  'package:xcross/src/shared/flutter/build/internal/swiftpm_binary_fixture.dart':
      {
        'CLASS:SwiftPmBinaryFixture': 'internal',
        'CLASS:SwiftPmBinaryFixtureGenerator': 'internal',
        'CLASS:SwiftPmBinaryFixtureLibrary': 'internal',
      },
  'package:xcross/src/shared/flutter/build/internal/swiftpm_workspace.dart': {
    'CLASS:SwiftPmWorkspace': 'internal',
  },
  'package:xcross/src/shared/flutter/build/internal/toolchain.dart': {
    'CLASS:Toolchain': 'internal',
  },
  'package:xcross/src/shared/flutter/build/internal/xcconfig_resolver.dart': {
    'CLASS:XcconfigComments': 'internal',
    'CLASS:XcconfigEvaluation': 'internal',
    'CLASS:XcconfigFileReader': 'internal',
    'CLASS:XcconfigResolver': 'internal',
    'TYPE_ALIAS:XcconfigSpecificity': 'internal',
  },
  'package:xcross/src/shared/flutter/build/ios_app_extensions.dart': {
    'CLASS:IosAppExtension': 'internal',
    'CLASS:IosAppExtensions': 'internal',
    'TOP_LEVEL_VARIABLE:_applicationProductType': 'private',
    'TOP_LEVEL_VARIABLE:_extensionProductTypes': 'private',
  },
  'package:xcross/src/shared/flutter/build/ios_bundle_id.dart': {
    'CLASS:IosBundleId': 'internal',
  },
  'package:xcross/src/shared/flutter/build/ios_bundle_resources.dart': {
    'CLASS:IosBundleResources': 'internal',
  },
  'package:xcross/src/shared/flutter/build/ios_bundle_versions.dart': {
    'CLASS:IosBundleVersions': 'internal',
  },
  'package:xcross/src/shared/flutter/build/ios_deployment_target.dart': {
    'CLASS:IosDeploymentTarget': 'internal',
  },
  'package:xcross/src/shared/flutter/build/ios_engine_cache.dart': {
    'CLASS:IosEngineCache': 'internal',
  },
  'package:xcross/src/shared/flutter/build/ios_linker_compatibility.dart': {
    'TOP_LEVEL_VARIABLE:objectiveCLinkerSwiftDriverArguments': 'internal',
    'TOP_LEVEL_VARIABLE:objectiveCSmallStubSwiftDriverArguments': 'internal',
  },
  'package:xcross/src/shared/flutter/build/ios_native_assets.dart': {
    'CLASS:IosNativeAssetsBuildResult': 'internal',
    'CLASS:IosNativeAssetsBuilder': 'internal',
  },
  'package:xcross/src/shared/flutter/build/ios_plugin_package.dart': {
    'CLASS:GeneratedPluginsBuildResult': 'internal',
    'CLASS:GeneratedPluginsPackage': 'internal',
    'CLASS:SwiftPmBinaryArtifactProvenance': 'internal',
    'CLASS:SwiftPmBinaryAttemptState': 'internal',
    'CLASS:SwiftPmPackageDependency': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
    'TYPE_ALIAS:ArtifactJunctionCapabilityResolver': 'internal',
    'TYPE_ALIAS:CreateSwiftPmBinaryAlias': 'internal',
    'TYPE_ALIAS:MaterializeSwiftPmBinaryArtifact': 'internal',
    'TYPE_ALIAS:PrepareSwiftPmBinaryArtifact': 'internal',
    'TYPE_ALIAS:SwiftPmDependencyRefEvaluator': 'internal',
  },
  'package:xcross/src/shared/flutter/build/ios_plugins.dart': {
    'CLASS:IosPlugin': 'internal',
    'CLASS:PluginDiscovery': 'internal',
  },
  'package:xcross/src/shared/flutter/build/macho_dylib_rewriter.dart': {
    'CLASS:MachODylibRewriter': 'internal',
  },
  'package:xcross/src/shared/flutter/build/macho_linkedit_aligner.dart': {
    'CLASS:MachOLinkeditAligner': 'internal',
  },
  'package:xcross/src/shared/flutter/build/objc_fast_stub_rewriter.dart': {
    'CLASS:FastObjCStub': 'internal',
    'CLASS:ObjCFastStubRewriter': 'internal',
  },
  'package:xcross/src/shared/flutter/build/pbxproj.dart': {
    'CLASS:PbxObject': 'internal',
    'CLASS:PbxProject': 'internal',
    'TOP_LEVEL_VARIABLE:_nonResourceExtensions': 'private',
    'TOP_LEVEL_VARIABLE:_sourceExtensions': 'private',
  },
  'package:xcross/src/shared/flutter/build/runner_shim.dart': {
    'CLASS:RunnerShim': 'internal',
  },
  'package:xcross/src/shared/flutter/build/swift_package_host_patches.dart': {
    'FUNCTION:_canStartSwiftExpression': 'private',
    'FUNCTION:_findFunctionBody': 'private',
    'FUNCTION:_isEscapedSwiftQuote': 'private',
    'FUNCTION:_macOSDirectiveRemovals': 'private',
    'FUNCTION:_matchingBrace': 'private',
    'FUNCTION:_swiftCodeMask': 'private',
    'FUNCTION:_swiftRegexEnd': 'private',
    'FUNCTION:exposeMacOSPackageGraphEntries': 'internal',
  },
  'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_preparer.dart':
      {
        'CLASS:SwiftPmBinaryArtifactPreparer': 'internal',
        'CLASS:SwiftPmPreparedBinaryArtifact': 'internal',
      },
  'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_store.dart':
      {
        'CLASS:SwiftPmBinaryArtifactEntry': 'internal',
        'CLASS:SwiftPmBinaryArtifactStore': 'internal',
      },
  'package:xcross/src/shared/flutter/build/swiftpm_binary_target.dart': {
    'CLASS:BinaryTargetDeclaration': 'internal',
    'CLASS:SwiftManifestParser': 'internal',
    'CLASS:SwiftPmBinaryTargetManifest': 'internal',
    'CLASS:SwiftPmRemoteBinaryTarget': 'internal',
  },
  'package:xcross/src/shared/flutter/constants.dart': {
    'CLASS:FlutterDeviceConstants': 'internal',
    'CLASS:GeneratedPluginsConstants': 'internal',
    'CLASS:IosDeploymentConstants': 'internal',
    'CLASS:PlistDefaults': 'internal',
    'TOP_LEVEL_VARIABLE:flutterArtifactBaseUrl': 'internal',
  },
  'package:xcross/src/shared/flutter/errors.dart': {
    'CLASS:FlutterBuildError': 'internal',
  },
  'package:xcross/src/shared/flutter/extensions/app_extension_plist.dart': {
    'CLASS:AppExtensionPlist': 'internal',
  },
  'package:xcross/src/shared/flutter/extensions/app_extension_resources.dart': {
    'CLASS:AppExtensionResources': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_artifact_compiler.dart': {
    'CLASS:FlutterArtifactCompiler': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_artifact_linker.dart': {
    'CLASS:FlutterArtifactLinker': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_assets_compiler.dart': {
    'CLASS:FlutterAssetsCompiler': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_build_options_resolver.dart': {
    'CLASS:FlutterBuildOptionsResolver': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_build_runtime.dart': {
    'CLASS:FlutterBuildRuntime': 'internal',
    'CLASS:FlutterResolutionConfiguration': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_build_steps.dart': {
    'CLASS:FlutterAssembleStep': 'internal',
    'CLASS:FlutterBuildContext': 'internal',
    'CLASS:FlutterBuildRequest': 'internal',
    'CLASS:FlutterCompileStep': 'internal',
    'CLASS:FlutterCompiledArtifacts': 'internal',
    'CLASS:FlutterLinkStep': 'internal',
    'CLASS:FlutterLinkedArtifacts': 'internal',
    'CLASS:FlutterResolveStep': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_bundle_assembler.dart': {
    'CLASS:FlutterBundleAssembler': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_framework_copier.dart': {
    'CLASS:FlutterFrameworkCopier': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_kernel_compiler.dart': {
    'CLASS:FlutterKernelCompiler': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_project_resolver.dart': {
    'CLASS:FlutterProjectResolver': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_workspace_overlay.dart': {
    'CLASS:FlutterWorkspaceOverlay': 'internal',
  },
  'package:xcross/src/shared/flutter/flutter_workspace_readiness.dart': {
    'CLASS:FlutterWorkspaceReadiness': 'internal',
  },
  'package:xcross/src/shared/flutter/hot_reload/dart_vm_service_client.dart': {
    'CLASS:DartVmServiceClient': 'internal',
    'TYPE_ALIAS:VmServiceHandler': 'internal',
  },
  'package:xcross/src/shared/flutter/hot_reload/hot_reload_controller.dart': {
    'CLASS:HotReloadController': 'internal',
  },
  'package:xcross/src/shared/flutter/hot_reload/internal/pending_call.dart': {
    'CLASS:PendingCall': 'internal',
  },
  'package:xcross/src/shared/flutter/hot_reload/source_watcher.dart': {
    'CLASS:SourceWatcher': 'internal',
  },
  'package:xcross/src/shared/flutter/hot_reload/vm_service_output.dart': {
    'CLASS:VmServiceOutput': 'internal',
  },
  'package:xcross/src/shared/flutter/models/flutter/dart_defines.dart': {
    'CLASS:DartDefines': 'internal',
  },
  'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart':
      {'CLASS:FlutterBuildOptions': 'internal'},
  'package:xcross/src/shared/flutter/models/hot_reload_config.dart': {
    'CLASS:HotReloadConfig': 'internal',
  },
  'package:xcross/src/shared/flutter/models/internal/pubspec_font.dart': {
    'CLASS:PubspecFontAsset': 'internal',
    'CLASS:PubspecFontFamily': 'internal',
  },
  'package:xcross/src/shared/flutter/models/pubspec_info.dart': {
    'CLASS:PubspecInfo': 'internal',
  },
  'package:xcross/src/shared/flutter/plugins/plugin_class_availability_scanner.dart':
      {'CLASS:PluginClassAvailabilityScanner': 'internal'},
  'package:xcross/src/shared/flutter/project/dart_defines_reader.dart': {
    'CLASS:DartDefinesReader': 'internal',
  },
  'package:xcross/src/shared/flutter/project/ios_bundle_versions_resolver.dart':
      {'CLASS:IosBundleVersionsResolver': 'internal'},
  'package:xcross/src/shared/flutter/project/ios_deployment_target_resolver.dart':
      {'CLASS:IosDeploymentTargetResolver': 'internal'},
  'package:xcross/src/shared/flutter/project/pbx_parser.dart': {
    'CLASS:PbxParser': 'internal',
  },
  'package:xcross/src/shared/flutter/project/pbx_project_reader.dart': {
    'CLASS:PbxProjectReader': 'internal',
  },
  'package:xcross/src/shared/flutter/project/pubspec_info_reader.dart': {
    'CLASS:PubspecInfoReader': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/artifact_archive_inspector.dart': {
    'CLASS:InspectedXcFrameworkArchive': 'internal',
    'CLASS:SwiftPmArtifactArchiveInspector': 'internal',
    'CLASS:ValidatedArchiveEntry': 'internal',
    'CLASS:XcFrameworkLibrary': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/artifact_capabilities.dart': {
    'CLASS:SwiftPmArtifactCapabilities': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart': {
    'CLASS:BinaryCopyProcess': 'internal',
    'CLASS:RunnerBinaryCopyProcess': 'internal',
    'CLASS:SwiftPmArtifactCopyPolicy': 'internal',
    'CLASS:SwiftPmLiveCopyException': 'internal',
    'TYPE_ALIAS:StartBinaryCopy': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/artifact_destination_publisher.dart':
      {
        'CLASS:SwiftPmArtifactDestinationPublisher': 'internal',
        'CLASS:SwiftPmBinaryArtifactPublication': 'internal',
      },
  'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart': {
    'CLASS:SwiftPmArtifactFileSystem': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/artifact_identity.dart': {
    'CLASS:SwiftPmArtifactIdentities': 'internal',
    'CLASS:SwiftPmArtifactIdentity': 'internal',
    'CLASS:SwiftPmArtifactIdentityResolver': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/artifact_offline_publisher.dart': {
    'CLASS:SwiftPmOfflineArtifactPublisher': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart':
      {
        'CLASS:SwiftPmPublicationCoordinator': 'internal',
        'CLASS:SwiftPmPublicationLock': 'internal',
        'CLASS:SwiftPmPublicationLockProvider': 'internal',
      },
  'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart': {
    'CLASS:HttpSwiftPmArchiveTransport': 'internal',
    'CLASS:SwiftPmArchiveTransport': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/artifact_tree.dart': {
    'CLASS:SwiftPmArtifactTree': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/assembly.dart': {
    'CLASS:SwiftPmAssembly': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/binary_layout.dart': {
    'CLASS:SwiftPmBinaryLayout': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/binary_preparation.dart': {
    'CLASS:SwiftPmBinaryPreparation': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart': {
    'CLASS:SwiftPmBinaryProvenance': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart': {
    'CLASS:SwiftPmBinaryRecovery': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/build_driver.dart': {
    'CLASS:SwiftPmBuildDriver': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/build_execution.dart': {
    'CLASS:SwiftPmBuildCommand': 'internal',
    'CLASS:SwiftPmBuildExecution': 'internal',
    'CLASS:SwiftPmInteropBuild': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/build_plan.dart': {
    'CLASS:SwiftPmBuildPlan': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/build_session.dart': {
    'CLASS:SwiftPmBuildSession': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/checkout.dart': {
    'CLASS:SwiftPmCheckout': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart': {
    'CLASS:SwiftPmCheckoutAttributes': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/checkout_containment.dart': {
    'CLASS:SwiftPmCheckoutContainment': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/checkout_git_repository.dart': {
    'CLASS:SwiftPmGitPackageCloner': 'internal',
    'CLASS:SwiftPmGitRepository': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/checkout_graph.dart': {
    'CLASS:SwiftPmCheckoutGraph': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/checkout_link_creator.dart': {
    'CLASS:SwiftPmCheckoutLinkCreator': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/checkout_link_policy.dart': {
    'CLASS:SwiftPmCheckoutFallback': 'internal',
    'CLASS:SwiftPmCheckoutGitPolicy': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/checkout_links.dart': {
    'CLASS:SwiftPmCheckoutLinks': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart':
      {
        'CLASS:SwiftPmCheckoutManifestNormalizer': 'internal',
        'CLASS:SwiftPmVendoredManifestPolicy': 'internal',
      },
  'package:xcross/src/shared/flutter/swiftpm/checkout_stamp.dart': {
    'CLASS:SwiftPmCheckoutStampValidator': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/clang_modules.dart': {
    'CLASS:SwiftPmClangModules': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/dependency_evaluator.dart': {
    'CLASS:SwiftPmDependencyEvaluator': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart': {
    'CLASS:SwiftPmDependencyArtifactCommand': 'internal',
    'CLASS:SwiftPmDependencyCommand': 'internal',
    'CLASS:SwiftPmDependencyPreparation': 'internal',
    'CLASS:SwiftPmPinnedDependencyCommand': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/dependency_vendor.dart': {
    'CLASS:SwiftPmDependencyVendor': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/discovery.dart': {
    'CLASS:SwiftPmDiscovery': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/extracted_artifact_recovery.dart':
      {
        'CLASS:SwiftPmExtractedArtifactRecovery': 'internal',
        'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
        'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
      },
  'package:xcross/src/shared/flutter/swiftpm/filesystem.dart': {
    'CLASS:SwiftPmFilesystem': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
    'TYPE_ALIAS:SwiftPmSourceTransform': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/foundation.dart': {
    'CLASS:SwiftPmFoundation': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/gate_evidence.dart': {
    'CLASS:DeepCollectionEquality': 'internal',
    'CLASS:SwiftPmGateEvidence': 'internal',
    'FUNCTION:_secureRandomByte': 'private',
    'FUNCTION:decodedSwiftPmGateMap': 'internal',
    'FUNCTION:validSwiftPmGateSdkIdentity': 'internal',
    'FUNCTION:validSwiftPmGateToolchainIdentity': 'internal',
    'TOP_LEVEL_VARIABLE:_extractorBuildVersion': 'private',
    'TOP_LEVEL_VARIABLE:_gateImplementationVersion': 'private',
    'TYPE_ALIAS:SwiftPmGateProbe': 'internal',
    'TYPE_ALIAS:SwiftPmGateRuntimeBinding': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/gate_execution.dart': {
    'CLASS:SwiftPmGateExecution': 'internal',
    'CLASS:SwiftPmGateLiveProcessException': 'internal',
    'CLASS:SwiftPmGateProcess': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/gate_mode.dart': {
    'ENUM:SwiftPmGateMode': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart': {
    'CLASS:SwiftPmGatePlatform': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart': {
    'CLASS:SwiftPmHostBuildServices': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/host_policy.dart': {
    'CLASS:SwiftPmHostPolicy': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart': {
    'CLASS:SwiftPmHostSourceNormalizer': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/interop_build_recovery.dart': {
    'CLASS:SwiftPmInteropBuildRecovery': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/interop_consumer_repair.dart': {
    'CLASS:SwiftPmInteropConsumerRepair': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/librarian_resolver.dart': {
    'CLASS:DarwinSwiftPmLlvmToolLookup': 'internal',
    'CLASS:SwiftPmLibrarianResolver': 'internal',
    'CLASS:SwiftPmLlvmToolLookup': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/manifest.dart': {
    'CLASS:SwiftPmManifest': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/manifest_dependencies.dart': {
    'CLASS:SwiftPmManifestDependencies': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart': {
    'CLASS:SwiftPmManifestLexer': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/module_files.dart': {
    'CLASS:SwiftPmModuleFiles': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/network_retry.dart': {
    'CLASS:SwiftPmNetworkRetry': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/manifest_target_alias.dart': {
    'CLASS:SwiftPmManifestTargetAlias': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart': {
    'CLASS:SwiftPmPackageMetadata': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/plan_reader.dart': {
    'CLASS:SwiftPmPlanReader': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/plugin_overlay.dart': {
    'CLASS:SwiftPmPluginOverlay': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/process_policy.dart': {
    'CLASS:SwiftPmProcessPolicy': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/response_arguments.dart': {
    'CLASS:SwiftPmResponseArguments': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/response_file_reader.dart': {
    'CLASS:SwiftPmResponseFileReader': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/runtime.dart': {
    'CLASS:SwiftPmRuntime': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart': {
    'CLASS:SwiftPmSdkIdentity': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/sdk_install_identity.dart': {
    'CLASS:SdkInstallSwiftPmIdentity': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/source_fallback.dart': {
    'CLASS:SwiftPmSourceFallback': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/source_repair.dart': {
    'CLASS:SwiftPmSourceRepair': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/toolchain.dart': {
    'CLASS:SwiftPmToolchain': 'internal',
  },
  'package:xcross/src/shared/flutter/swiftpm/workspace_stager.dart': {
    'CLASS:SwiftPmWorkspaceStager': 'internal',
    'TOP_LEVEL_VARIABLE:flutterFrameworkPackageName': 'internal',
    'TOP_LEVEL_VARIABLE:pluginsProductName': 'internal',
    'TYPE_ALIAS:SwiftPmSourceTransform': 'internal',
  },
  'package:xcross/src/shared/flutter/vm_service_connector.dart': {
    'CLASS:LocalVmServiceConnector': 'internal',
    'CLASS:VmServiceConnector': 'internal',
  },
};
