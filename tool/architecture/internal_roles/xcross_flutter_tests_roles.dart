import 'package:meta/meta.dart';

@internal
const xcrossFlutterTestsRoles = <String, Map<String, String>>{
  'workspace:packages/xcross/test/flutter/build/app_extension_builder_test.dart':
      {
        'FUNCTION:_extension': 'private',
        'FUNCTION:main': 'entrypoint',
        'FUNCTION:testExtensionBuilder': 'internal',
        'FUNCTION:testExtensionResources': 'internal',
      },
  'workspace:packages/xcross/test/flutter/build/apple_tool_shim_templates_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/apple_tool_shims_test.dart': {
    'CLASS:MappedXcrunFileSystem': 'internal',
    'CLASS:SelectedOtoolLocations': 'internal',
    'CLASS:XcrunTestProcesses': 'internal',
    'FUNCTION:constructorOwnedOtoolTests': 'internal',
    'FUNCTION:declarativeXcrunTests': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/build/dart_plugin_registrant_test.dart':
      {
        'CLASS:KernelNamespaceFileSystem': 'internal',
        'FUNCTION:_frontendServerFlags': 'private',
        'FUNCTION:main': 'entrypoint',
      },
  'workspace:packages/xcross/test/flutter/build/flutter_artifact_capabilities_test.dart':
      {
        'CLASS:MutableSwiftPmArtifactIdentities': 'internal',
        'FUNCTION:_deleteTemp': 'private',
        'FUNCTION:main': 'entrypoint',
        'TOP_LEVEL_VARIABLE:_runtime': 'private',
        'TOP_LEVEL_VARIABLE:_windowsRuntime': 'private',
      },
  'workspace:packages/xcross/test/flutter/build/flutter_asset_arguments_test.dart':
      {'FUNCTION:_decodedDefines': 'private', 'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/flutter_bundle_assembly_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/flutter_debug_bundler_scratch_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/flutter_notice_artifact_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/flutter_packer_test.dart': {
    'CLASS:RecordingFlutterSdkPolicy': 'internal',
    'FUNCTION:_deleteTemp': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/build/flutter_pipeline_test.dart': {
    'CLASS:RecordingFlutterPipeline': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/build/flutter_target_policy_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/flutter_tool_workspace_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/flutter_workspace_readiness_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/git_blob_batch_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/build/hot_reload_setup_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/build/info_plist_test.dart': {
    'FUNCTION:applyIPhoneRequiredKeys': 'internal',
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_minimalPlist': 'private',
  },
  'workspace:packages/xcross/test/flutter/build/ios_app_extensions_test.dart': {
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_pbxproj': 'private',
  },
  'workspace:packages/xcross/test/flutter/build/ios_bundle_id_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/build/ios_bundle_resources_test.dart':
      {
        'FUNCTION:_bundleFile': 'private',
        'FUNCTION:_file': 'private',
        'FUNCTION:_stage': 'private',
        'FUNCTION:_writeProject': 'private',
        'FUNCTION:main': 'entrypoint',
      },
  'workspace:packages/xcross/test/flutter/build/ios_bundle_versions_test.dart':
      {'FUNCTION:main': 'entrypoint', 'TOP_LEVEL_VARIABLE:_pbxproj': 'private'},
  'workspace:packages/xcross/test/flutter/build/ios_deployment_target_propagation_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/ios_deployment_target_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/ios_engine_cache_test.dart': {
    'CLASS:NativeTestLogOutput': 'internal',
    'FUNCTION:_downloader': 'private',
    'FUNCTION:_log': 'private',
    'FUNCTION:_unixZip': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/build/ios_linker_compatibility_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/ios_native_assets_test.dart': {
    'FUNCTION:_dylibMachO': 'private',
    'FUNCTION:_dylibNames': 'private',
    'FUNCTION:main': 'entrypoint',
    'FUNCTION:nativeHookDiscovery': 'internal',
  },
  'workspace:packages/xcross/test/flutter/build/ios_plugin_package_test.dart': {
    'FUNCTION:_emptyMachO': 'private',
    'FUNCTION:binaryProvenance': 'internal',
    'FUNCTION:main': 'entrypoint',
    'FUNCTION:packageSrcPath': 'internal',
    'FUNCTION:swiftPath': 'internal',
    'TOP_LEVEL_VARIABLE:_plugins': 'private',
    'TOP_LEVEL_VARIABLE:_swiftPmRuntime': 'private',
    'TOP_LEVEL_VARIABLE:_windowsRuntime': 'private',
  },
  'workspace:packages/xcross/test/flutter/build/ios_plugins_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/build/ios_swift_state_recovery_test.dart':
      {
        'FUNCTION:diagnostic': 'internal',
        'FUNCTION:main': 'entrypoint',
        'TOP_LEVEL_VARIABLE:_swiftPmRuntime': 'private',
      },
  'workspace:packages/xcross/test/flutter/build/macho_dylib_rewriter_test.dart':
      {
        'FUNCTION:_dylibNames': 'private',
        'FUNCTION:_macho': 'private',
        'FUNCTION:_objcMacho': 'private',
        'FUNCTION:_putName': 'private',
        'FUNCTION:_putSegment': 'private',
        'FUNCTION:_putStub': 'private',
        'FUNCTION:main': 'entrypoint',
        'TOP_LEVEL_VARIABLE:_idDylib': 'private',
        'TOP_LEVEL_VARIABLE:_loadDylib': 'private',
        'TOP_LEVEL_VARIABLE:_loadUpwardDylib': 'private',
        'TOP_LEVEL_VARIABLE:_loadWeakDylib': 'private',
        'TOP_LEVEL_VARIABLE:_reexportDylib': 'private',
      },
  'workspace:packages/xcross/test/flutter/build/macho_linkedit_aligner_test.dart':
      {
        'FUNCTION:buildMachO': 'internal',
        'FUNCTION:main': 'entrypoint',
        'FUNCTION:readSymtab': 'internal',
        'FUNCTION:stringTable': 'internal',
      },
  'workspace:packages/xcross/test/flutter/build/native_asset_linking_test.dart':
      {'FUNCTION:_writeMachO': 'private', 'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/native_asset_staging_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/native_assets_manifest_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/plugin_registrant_availability_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/recursive_directory_copy_test.dart':
      {'CLASS:MappedCopyFileSystem': 'internal', 'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/runner_shim_source_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/build/support/checkout_test_context.dart':
      {
        'CLASS:CheckoutCommand': 'internal',
        'CLASS:CheckoutInputConsumer': 'internal',
        'CLASS:CheckoutLogOutput': 'internal',
        'CLASS:CheckoutTestContext': 'internal',
        'CLASS:CheckoutTestProcess': 'internal',
        'CLASS:RecordingCheckoutProcesses': 'internal',
      },
  'workspace:packages/xcross/test/flutter/build/support/dependency_preparation_test_context.dart':
      {
        'CLASS:RecordingDependencyCloner': 'internal',
        'CLASS:RecordingDependencyManifestPolicy': 'internal',
        'CLASS:RejectingDependencyArchiveTransport': 'internal',
        'CLASS:RejectingDependencyNativeTools': 'internal',
        'FUNCTION:dependencyTestPreparation': 'internal',
      },
  'workspace:packages/xcross/test/flutter/build/support/native_asset_framework_fixtures.dart':
      {
        'CLASS:FrameworkLipoChild': 'internal',
        'CLASS:FrameworkLipoProcesses': 'internal',
        'FUNCTION:nativeFrameworkService': 'internal',
      },
  'workspace:packages/xcross/test/flutter/build/support/native_flutter_fixtures.dart':
      {
        'CLASS:NativeTestLogOutput': 'internal',
        'CLASS:WindowsFixtureProcesses': 'internal',
        'FUNCTION:appleToolResolver': 'internal',
        'FUNCTION:expectWorkspaceSdk': 'internal',
        'FUNCTION:nativeAssetTree': 'internal',
        'FUNCTION:nativeHostCases': 'internal',
        'FUNCTION:nativeLinuxEngineCache': 'internal',
        'FUNCTION:nativeTestDownloader': 'internal',
        'FUNCTION:nativeTestLog': 'internal',
        'FUNCTION:nativeTestSink': 'internal',
        'FUNCTION:windowsFixtureHost': 'internal',
        'FUNCTION:workspaceSdk': 'internal',
      },
  'workspace:packages/xcross/test/flutter/build/swift_package_host_patches_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/swiftpm_artifact_publication_coordinator_test.dart':
      {
        'CLASS:FailingPublicationLock': 'internal',
        'CLASS:FailingPublicationLockProvider': 'internal',
        'FUNCTION:main': 'entrypoint',
      },
  'workspace:packages/xcross/test/flutter/build/swiftpm_binary_artifact_preparer_test.dart':
      {
        'CLASS:ArchiveFixture': 'internal',
        'CLASS:CallbackSwiftPmArchiveTransport': 'internal',
        'CLASS:FailingQuarantineFile': 'internal',
        'CLASS:FailingQuarantineFileSystem': 'internal',
        'CLASS:FakeBinaryCopyProcess': 'internal',
        'CLASS:FakeProcess': 'internal',
        'FUNCTION:_bytesEqual': 'private',
        'FUNCTION:_uint16': 'private',
        'FUNCTION:_uint32': 'private',
        'FUNCTION:addEntries': 'internal',
        'FUNCTION:copyDirectorySync': 'internal',
        'FUNCTION:corruptZipEntry': 'internal',
        'FUNCTION:createFixture': 'internal',
        'FUNCTION:createRawXcframework': 'internal',
        'FUNCTION:emptyMachO': 'internal',
        'FUNCTION:expectMaterializationAbsent': 'internal',
        'FUNCTION:main': 'entrypoint',
        'FUNCTION:markZipEntryAsUnix': 'internal',
        'FUNCTION:readPlist': 'internal',
        'FUNCTION:replaceAscii': 'internal',
        'FUNCTION:stagingFiles': 'internal',
        'FUNCTION:target': 'internal',
        'FUNCTION:throwsBuildErrorContaining': 'internal',
        'FUNCTION:writeAliasMarker': 'internal',
        'FUNCTION:writeArchive': 'internal',
        'FUNCTION:writeRawXcframeworkZip': 'internal',
        'FUNCTION:xcframeworkEntries': 'internal',
        'FUNCTION:xcframeworkPlist': 'internal',
        'TOP_LEVEL_VARIABLE:_simulatorRuntime': 'private',
        'TOP_LEVEL_VARIABLE:_swiftPmRuntime': 'private',
        'TOP_LEVEL_VARIABLE:_windowsRuntime': 'private',
        'TOP_LEVEL_VARIABLE:defaultLibraries': 'internal',
        'TOP_LEVEL_VARIABLE:windowsGateSkip': 'internal',
      },
  'workspace:packages/xcross/test/flutter/build/swiftpm_binary_artifact_store_test.dart':
      {
        'FUNCTION:fixture': 'internal',
        'FUNCTION:main': 'entrypoint',
        'FUNCTION:publishFixture': 'internal',
        'TOP_LEVEL_VARIABLE:_abcChecksum': 'private',
        'TOP_LEVEL_VARIABLE:_defChecksum': 'private',
        'TOP_LEVEL_VARIABLE:_swiftPmRuntime': 'private',
      },
  'workspace:packages/xcross/test/flutter/build/swiftpm_binary_download_timeout_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/swiftpm_binary_target_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/swiftpm_checkout_git_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/swiftpm_checkout_graph_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/swiftpm_checkout_policy_test.dart':
      {
        'CLASS:FixtureVendoredManifestPolicy': 'internal',
        'CLASS:RecordingCheckoutAttributes': 'internal',
        'FUNCTION:main': 'entrypoint',
      },
  'workspace:packages/xcross/test/flutter/build/swiftpm_cross_host_test.dart': {
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_swiftPmRuntime': 'private',
    'TOP_LEVEL_VARIABLE:_windowsRuntime': 'private',
  },
  'workspace:packages/xcross/test/flutter/build/swiftpm_dependency_preparation_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/swiftpm_preview_macro_compiler_test.dart':
      {
        'CLASS:RecordingSwiftPmNativeCompiler': 'internal',
        'FUNCTION:main': 'entrypoint',
      },
  'workspace:packages/xcross/test/flutter/build/swiftpm_resolve_retry_test.dart':
      {
        'FUNCTION:main': 'entrypoint',
        'TOP_LEVEL_VARIABLE:_swiftPmRuntime': 'private',
      },
  'workspace:packages/xcross/test/flutter/build/swiftpm_simulator_gate_test.dart':
      {
        'CLASS:ControlledGateTestProcess': 'internal',
        'CLASS:GateTestLogOutput': 'internal',
        'CLASS:GateThrowingCancelStream': 'internal',
        'CLASS:GateThrowingCancelSubscription': 'internal',
        'CLASS:MappedGateFixtureFileSystem': 'internal',
        'CLASS:RecordingGateTestProcess': 'internal',
        'FUNCTION:createGateTestSdk': 'internal',
        'FUNCTION:createGateTestToolchain': 'internal',
        'FUNCTION:main': 'entrypoint',
      },
  'workspace:packages/xcross/test/flutter/build/swiftpm_test_context.dart': {
    'CLASS:FixtureSwiftPmArchiveTransport': 'internal',
    'CLASS:FixtureSwiftPmLlvmToolLookup': 'internal',
    'CLASS:RecordingPosixSwiftPmExecution': 'internal',
    'CLASS:RecordingSwiftPmGitPackageCloner': 'internal',
    'CLASS:RecordingSwiftPmInteropBuild': 'internal',
    'CLASS:RecordingWindowsSwiftPmExecution': 'internal',
    'CLASS:TestLogOutput': 'internal',
    'CLASS:TestSwiftPmSdkIdentity': 'internal',
    'CLASS:WindowsTestPaths': 'internal',
    'FUNCTION:testGenericInteropRecovery': 'internal',
    'FUNCTION:testPosixInteropRecovery': 'internal',
    'FUNCTION:testPosixToolchainLookup': 'internal',
    'FUNCTION:testSimulatorSwiftPmRuntime': 'internal',
    'FUNCTION:testSwiftPmLog': 'internal',
    'FUNCTION:testSwiftPmRuntime': 'internal',
    'FUNCTION:testWindowsInteropRecovery': 'internal',
    'FUNCTION:testWindowsPinnedResolver': 'internal',
    'FUNCTION:testWindowsSimulatorSwiftPmRuntime': 'internal',
    'FUNCTION:testWindowsSwiftPmRuntime': 'internal',
    'FUNCTION:testWindowsToolchainLookup': 'internal',
  },
  'workspace:packages/xcross/test/flutter/build/swiftpm_workspace_test.dart': {
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_simulatorRuntime': 'private',
    'TOP_LEVEL_VARIABLE:_swiftPmRuntime': 'private',
  },
  'workspace:packages/xcross/test/flutter/build/windows_directory_copy_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/windows_flutter_sdk_policy_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/flutter/build/windows_swift_response_test.dart':
      {
        'FUNCTION:main': 'entrypoint',
        'TOP_LEVEL_VARIABLE:_swiftPmRuntime': 'private',
        'TOP_LEVEL_VARIABLE:_windowsRepairs': 'private',
        'TOP_LEVEL_VARIABLE:_windowsRuntime': 'private',
      },
  'workspace:packages/xcross/test/flutter/dart_defines_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/flutter_build_options_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/flutter_test_log.dart': {
    'CLASS:RecordingFlutterLogOutput': 'internal',
    'FUNCTION:testFlutterLog': 'internal',
  },
  'workspace:packages/xcross/test/flutter/flutter_test_runtime.dart': {
    'CLASS:TestSwiftPmSdkIdentity': 'internal',
    'FUNCTION:testFlutterRuntime': 'internal',
    'FUNCTION:testIPhoneRuntime': 'internal',
    'FUNCTION:testSimulatorRuntime': 'internal',
  },
  'workspace:packages/xcross/test/flutter/hot_reload_controller_test.dart': {
    'CLASS:ReloadCompilerFactory': 'internal',
    'CLASS:ReloadCompilerTransport': 'internal',
    'CLASS:ReloadConnector': 'internal',
    'CLASS:ReloadHttpClient': 'internal',
    'CLASS:ReloadHttpHeaders': 'internal',
    'CLASS:ReloadHttpRequest': 'internal',
    'CLASS:ReloadHttpResponse': 'internal',
    'CLASS:ReloadMappedFileSystem': 'internal',
    'CLASS:ReloadRpcChannel': 'internal',
    'CLASS:ReloadRpcSink': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/pubspec_info_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/source_watcher_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/vm_service_output_live_test.dart': {
    'FUNCTION:_noLoopbackProxy': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/vm_service_output_test.dart': {
    'FUNCTION:_log': 'private',
    'FUNCTION:_write': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/flutter/vm_service_rpc_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
};
