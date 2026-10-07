import 'package:meta/meta.dart';

@internal
const xcrossSharedRoles = <String, Map<String, String>>{
  'package:xcross/src/shared/apple/arm64_instructions.dart': {
    'CLASS:Arm64AdrpLdr': 'internal',
  },
  'package:xcross/src/shared/apple/mach_o.dart': {
    'CLASS:MachOConstants': 'internal',
    'CLASS:MachOFile': 'internal',
    'CLASS:MachOLoadCommand': 'internal',
    'CLASS:MachOSection': 'internal',
    'CLASS:MachOSymbol': 'internal',
    'CLASS:MachOSymbolTable': 'internal',
    'TYPE_ALIAS:InvalidMachO': 'internal',
  },
  'package:xcross/src/shared/apple/mach_o_code_signature.dart': {
    'CLASS:MachOCodeSignature': 'internal',
  },
  'package:xcross/src/shared/artifact/app_capabilities.dart': {
    'CLASS:AppCapabilities': 'internal',
  },
  'package:xcross/src/shared/artifact/app_entitlements.dart': {
    'CLASS:AppEntitlements': 'internal',
  },
  'package:xcross/src/shared/artifact/embedded_extension.dart': {
    'CLASS:AppExtensionEntitlements': 'internal',
    'CLASS:EmbeddedExtension': 'internal',
  },
  'package:xcross/src/shared/artifact/plist_mutations.dart': {
    'CLASS:PlistMutations': 'internal',
  },
  'package:xcross/src/shared/artifact/plist_storyboard_policy.dart': {
    'CLASS:PlistStoryboardPolicy': 'internal',
  },
  'package:xcross/src/shared/artifact/plist_xml.dart': {
    'CLASS:PlistXml': 'internal',
  },
  'package:xcross/src/shared/auth/signing_session.dart': {
    'CLASS:SigningSession': 'internal',
  },
  'package:xcross/src/shared/cli/basic/auth_command.dart': {
    'CLASS:AuthArgs': 'internal',
    'CLASS:AuthCommand': 'internal',
    r'FUNCTION:_$parseAuthArgsResult': 'private',
    r'FUNCTION:_$populateAuthArgsParser': 'private',
    'FUNCTION:parseAuthArgs': 'library-internal',
    r'TOP_LEVEL_VARIABLE:_$parserForAuthArgs': 'private',
    'TOP_LEVEL_VARIABLE:_authOptionNames': 'private',
  },
  'package:xcross/src/shared/cli/basic/completion_command.dart': {
    'CLASS:CompletionCommand': 'internal',
  },
  'package:xcross/src/shared/cli/basic/config_command.dart': {
    'CLASS:ConfigCommand': 'internal',
    'CLASS:ConfigShowCommand': 'internal',
    'CLASS:ConfigValidateCommand': 'internal',
    'TYPE_ALIAS:ConfigWriteLine': 'internal',
  },
  'package:xcross/src/shared/cli/basic/config_tui_controller.dart': {
    'CLASS:ConfigTuiController': 'internal',
    'ENUM:ConfigAction': 'internal',
    'ENUM:ConfigRoot': 'internal',
    'ENUM:ConfigTab': 'internal',
    'ENUM:ConfigToolchain': 'internal',
    'EXTENSION:@622': 'private',
    'EXTENSION:@913': 'private',
    'TYPE_ALIAS:ConfigConfirm': 'internal',
    'TYPE_ALIAS:ConfigPrompt': 'internal',
  },
  'package:xcross/src/shared/cli/basic/doctor_command.dart': {
    'CLASS:DoctorCommand': 'internal',
    'TYPE_ALIAS:DoctorWriteLine': 'internal',
  },
  'package:xcross/src/shared/cli/basic/doctor_environment_checks.dart': {
    'CLASS:DoctorEnvironmentChecks': 'internal',
  },
  'package:xcross/src/shared/cli/basic/doctor_models.dart': {
    'CLASS:DoctorCheck': 'internal',
    'CLASS:DoctorSection': 'internal',
    'ENUM:DoctorStatus': 'internal',
    'EXTENSION:DoctorStatusWorst': 'internal',
    'TYPE_ALIAS:DoctorExamine': 'internal',
  },
  'package:xcross/src/shared/cli/basic/internal/clang_requirement.dart': {
    'CLASS:ClangRequirement': 'internal',
  },
  'package:xcross/src/shared/cli/basic/internal/hard_link_payloads.dart': {
    'CLASS:CpioHardLinkKey': 'internal',
    'CLASS:HardLinkPayload': 'internal',
    'CLASS:HardLinkPayloads': 'internal',
  },
  'package:xcross/src/shared/cli/basic/internal/swift_requirement.dart': {
    'CLASS:SwiftRequirement': 'internal',
  },
  'package:xcross/src/shared/cli/basic/internal/swift_sibling_clang.dart': {
    'CLASS:SwiftSiblingClang': 'internal',
  },
  'package:xcross/src/shared/cli/basic/sdk_command.dart': {
    'CLASS:SdkCleanCommand': 'internal',
    'CLASS:SdkCommand': 'internal',
    'CLASS:SdkInstallCommand': 'internal',
  },
  'package:xcross/src/shared/cli/basic/sdk_install.dart': {
    'CLASS:SdkInstall': 'internal',
  },
  'package:xcross/src/shared/cli/basic/setup_command.dart': {
    'CLASS:SetupCommand': 'internal',
  },
  'package:xcross/src/shared/cli/basic/update_command.dart': {
    'CLASS:UpdateArgs': 'internal',
    'CLASS:UpdateCommand': 'internal',
    r'FUNCTION:_$parseUpdateArgsResult': 'private',
    r'FUNCTION:_$populateUpdateArgsParser': 'private',
    'FUNCTION:parseUpdateArgs': 'library-internal',
    r'TOP_LEVEL_VARIABLE:_$parserForUpdateArgs': 'private',
  },
  'package:xcross/src/shared/cli/command_prompt.dart': {
    'CLASS:CommandPrompt': 'internal',
  },
  'package:xcross/src/shared/cli/device_selection.dart': {
    'ENUM:DeviceConnection': 'internal',
    'FUNCTION:deviceSearchMode': 'internal',
  },
  'package:xcross/src/shared/cli/compose/compose_clean_command.dart': {
    'CLASS:ComposeCleanCommand': 'internal',
  },
  'package:xcross/src/shared/cli/flutter/subcommands/dap_command.dart': {
    'CLASS:DapCommand': 'internal',
  },
  'package:xcross/src/shared/cli/flutter/subcommands/flutter_clean_command.dart':
      {'CLASS:FlutterCleanCommand': 'internal'},
  'package:xcross/src/shared/cli/ide/ide_command.dart': {
    'CLASS:IdeCommand': 'internal',
  },
  'package:xcross/src/shared/cli/ide/subcommands/idea_command.dart': {
    'CLASS:IdeaCommand': 'internal',
  },
  'package:xcross/src/shared/cli/ide/subcommands/vscode_command.dart': {
    'CLASS:VscodeCommand': 'internal',
    'TOP_LEVEL_VARIABLE:_shim': 'private',
  },
  'package:xcross/src/shared/cli/ide/subcommands/vscode_json_merge.dart': {
    'CLASS:VscodeJsonMerge': 'internal',
    'TOP_LEVEL_VARIABLE:dapPathSetting': 'internal',
    'TOP_LEVEL_VARIABLE:dapPathValue': 'internal',
    'TOP_LEVEL_VARIABLE:promptErrorsSetting': 'internal',
    'TOP_LEVEL_VARIABLE:xcrossEnvKey': 'internal',
    'TOP_LEVEL_VARIABLE:xcrossEnvValue': 'internal',
    'TOP_LEVEL_VARIABLE:xcrossLaunchName': 'internal',
  },
  'package:xcross/src/shared/cli/ide/xcross_executable.dart': {
    'CLASS:XcrossIdeLauncher': 'internal',
  },
  'package:xcross/src/shared/cli/internal/parsed_command.dart': {
    'CLASS:ParsedCommand': 'internal',
  },
  'package:xcross/src/shared/cli/internal/xcross_runner.dart': {
    'CLASS:XcrossGlobalArgs': 'internal',
    'CLASS:XcrossRunner': 'internal',
    r'FUNCTION:_$parseXcrossGlobalArgsResult': 'private',
    r'FUNCTION:_$populateXcrossGlobalArgsParser': 'private',
    'FUNCTION:parseXcrossGlobalArgs': 'library-internal',
    r'TOP_LEVEL_VARIABLE:_$parserForXcrossGlobalArgs': 'private',
  },
  'package:xcross/src/shared/cli/shared/clean_paths.dart': {
    'CLASS:CleanPaths': 'internal',
  },
  'package:xcross/src/shared/cli/shared/ipa_packager.dart': {
    'CLASS:IpaPackager': 'internal',
  },
  'package:xcross/src/shared/config/config.dart': {
    'CLASS:ConfigNotProvided': 'internal',
    'CLASS:XcrossConfig': 'internal',
    'CLASS:XcrossConfigException': 'internal',
    'CLASS:XcrossConfigRoots': 'internal',
    'CLASS:XcrossConfigToolchains': 'internal',
    'FUNCTION:_sorted': 'private',
    'FUNCTION:_sortedObjects': 'private',
    'FUNCTION:_yamlString': 'private',
    'TOP_LEVEL_VARIABLE:_notProvided': 'private',
  },
  'package:xcross/src/shared/config/config_decoder.dart': {
    'CLASS:XcrossConfigDecoder': 'internal',
    'CLASS:XcrossConfigValidator': 'internal',
    'FUNCTION:_expandedString': 'private',
    'FUNCTION:_expandedStringList': 'private',
    'FUNCTION:_onlyKeys': 'private',
    'FUNCTION:_stringMap': 'private',
    'FUNCTION:expandNativeEnvironment': 'internal',
    'FUNCTION:rejectUnsafeConfigString': 'internal',
    'TOP_LEVEL_VARIABLE:_maximumEnvironmentExpansionDepth': 'private',
  },
  'package:xcross/src/shared/config/config_host.dart': {
    'CLASS:ConfigHostInterface': 'internal',
  },
  'package:xcross/src/shared/config/config_store.dart': {
    'CLASS:XcrossConfigStore': 'internal',
  },
  'package:xcross/src/shared/config/runtime_config.dart': {
    'CLASS:XcrossRuntimeConfig': 'internal',
  },
  'package:xcross/src/shared/dap/dap_child_controller.dart': {
    'CLASS:DapChildController': 'internal',
  },
  'package:xcross/src/shared/dap/dap_router.dart': {
    'CLASS:DapFrame': 'internal',
    'CLASS:DapFrameParser': 'internal',
    'CLASS:DapMessage': 'internal',
    'CLASS:DapResponseFilter': 'internal',
    'CLASS:DapSession': 'internal',
  },
  'package:xcross/src/shared/dap/internal/dap_router.dart': {
    'CLASS:DapRouter': 'internal',
  },
  'package:xcross/src/shared/dap/xcross_dap.dart': {
    'CLASS:XcrossDap': 'internal',
  },
  'package:xcross/src/shared/device/signing_http_client_factory.dart': {
    'CLASS:SigningHttpClientFactory': 'internal',
  },
  'package:xcross/src/shared/errors/errors.dart': {
    'CLASS:XcrossError': 'internal',
  },
  'package:xcross/src/shared/models/pack_result.dart': {
    'CLASS:PackResult': 'internal',
    'ENUM:PackOutputKind': 'internal',
  },
  'package:xcross/src/shared/packages/package_config_resolver.dart': {
    'CLASS:PackageConfigResolver': 'internal',
  },
  'package:xcross/src/shared/runtime/compose_host_provider.dart': {
    'CLASS:ComposeHostProvider': 'internal',
  },
  'package:xcross/src/shared/runtime/compose_simulator_capability.dart': {
    'CLASS:ComposeSimulatorCapability': 'internal',
  },
  'package:xcross/src/shared/runtime/constants.dart': {
    'CLASS:DeviceConstants': 'internal',
  },
  'package:xcross/src/shared/runtime/flutter_feature_services.dart': {
    'CLASS:FlutterFeatureServices': 'internal',
  },
  'package:xcross/src/shared/runtime/version.dart': {
    'CLASS:XcrossVersion': 'internal',
    'TOP_LEVEL_VARIABLE:_xcrossBuildReleased': 'private',
    'TOP_LEVEL_VARIABLE:_xcrossBuildVersion': 'private',
  },
  'package:xcross/src/shared/runtime/xcross_runtime.dart': {
    'CLASS:XcrossRuntime': 'internal',
  },
  'package:xcross/src/shared/sdk/sdk_archive_extraction.dart': {
    'CLASS:SdkArchiveExtraction': 'internal',
  },
  'package:xcross/src/shared/sdk/sdk_archive_links.dart': {
    'CLASS:SdkArchiveLinksInterface': 'internal',
  },
  'package:xcross/src/shared/sdk/sdk_archive_paths.dart': {
    'CLASS:SdkArchivePaths': 'internal',
  },
  'package:xcross/src/shared/sdk/sdk_build_identity.dart': {
    'CLASS:SdkBuildIdentity': 'internal',
  },
  'package:xcross/src/shared/sdk/sdk_bundle_metadata_writer.dart': {
    'CLASS:SdkBundleMetadataWriter': 'internal',
  },
  'package:xcross/src/shared/sdk/sdk_directory_copy.dart': {
    'CLASS:SdkDirectoryCopy': 'internal',
  },
  'package:xcross/src/shared/sdk/sdk_install_constants.dart': {
    'FUNCTION:sdkFirstToolchainLine': 'internal',
    'TOP_LEVEL_VARIABLE:hostToolchainStampName': 'internal',
    'TOP_LEVEL_VARIABLE:sdkAnyExecuteBit': 'internal',
    'TOP_LEVEL_VARIABLE:sdkDirectoryFileType': 'internal',
    'TOP_LEVEL_VARIABLE:sdkFileTypeMask': 'internal',
    'TOP_LEVEL_VARIABLE:sdkIncludedFiles': 'internal',
    'TOP_LEVEL_VARIABLE:sdkIncludedRoots': 'internal',
    'TOP_LEVEL_VARIABLE:sdkJsonEncoder': 'internal',
    'TOP_LEVEL_VARIABLE:sdkRegularFileType': 'internal',
    'TOP_LEVEL_VARIABLE:sdkSwiftResourcesRelativePath': 'internal',
    'TOP_LEVEL_VARIABLE:sdkSwiftStaticResourcesRelativePath': 'internal',
    'TOP_LEVEL_VARIABLE:sdkSymbolicLinkFileType': 'internal',
    'TOP_LEVEL_VARIABLE:sdkToolchainRelativePath': 'internal',
    'TOP_LEVEL_VARIABLE:swiftSdkMismatchMarker': 'internal',
  },
  'package:xcross/src/shared/sdk/sdk_json_file_writer.dart': {
    'CLASS:SdkJsonFileWriter': 'internal',
  },
  'package:xcross/src/shared/sdk/sdk_metadata_platform.dart': {
    'CLASS:SdkMetadataPlatformInterface': 'internal',
  },
  'package:xcross/src/shared/sdk/sdk_swift_toolchain.dart': {
    'CLASS:SdkSwiftToolchain': 'internal',
  },
  'package:xcross/src/shared/sdk/swift_toolchain_host.dart': {
    'CLASS:SwiftToolchainHostInterface': 'internal',
  },
  'package:xcross/src/shared/sdk/xcode_swift_requirement.dart': {
    'CLASS:XcodeSwiftRequirement': 'internal',
    'TOP_LEVEL_VARIABLE:_minimumSwiftForXcode': 'private',
    'TOP_LEVEL_VARIABLE:_swiftVersionPattern': 'private',
    'TOP_LEVEL_VARIABLE:_versionedNamePattern': 'private',
  },
  'package:xcross/src/shared/setup/host_operations.dart': {
    'CLASS:HostOperations': 'internal',
  },
  'package:xcross/src/shared/sdk/swift_environment_host.dart': {
    'CLASS:SwiftEnvironmentHostInterface': 'internal',
  },
  'package:xcross/src/shared/setup/setup_requirements.dart': {
    'CLASS:SetupConsole': 'internal',
    'CLASS:SetupRequirementServices': 'internal',
    'CLASS:SetupRequirements': 'internal',
  },
  'package:xcross/src/shared/setup/setup_script.dart': {
    'CLASS:SetupScriptManager': 'internal',
    'TYPE_ALIAS:SetupScriptApproval': 'internal',
    'TYPE_ALIAS:SetupScriptDownload': 'internal',
    'TYPE_ALIAS:SetupScriptExecute': 'internal',
  },
  'package:xcross/src/shared/setup/setup_script_policy.dart': {
    'CLASS:SetupScriptPolicy': 'internal',
    'TYPE_ALIAS:DefaultSetupScript': 'internal',
  },
  'package:xcross/src/shared/tool/mach_o_slices.dart': {
    'FUNCTION:arm64SliceRange': 'internal',
  },
  'package:xcross/src/shared/tool/tool_alias_operation.dart': {
    'CLASS:ToolAliasOperation': 'internal',
    'TYPE_ALIAS:ToolAliasRun': 'internal',
  },
  'package:xcross/src/shared/tools/swiftpm_gate_operation.dart': {
    'CLASS:SwiftPmGateOperation': 'internal',
    'CLASS:SwiftPmGateRuntimeLoader': 'internal',
    'CLASS:SwiftPmGateServices': 'internal',
    'TYPE_ALIAS:SwiftPmGateVerify': 'internal',
  },
  'package:xcross/src/shared/update/checksums.dart': {
    'CLASS:Checksums': 'internal',
  },
  'package:xcross/src/shared/update/git_ref_source_bundle_builder.dart': {
    'CLASS:GitRefSourceBundleBuilder': 'internal',
    'TYPE_ALIAS:DartExecutableLocator': 'internal',
    'TYPE_ALIAS:TempDirectoryModifiedAt': 'internal',
  },
  'package:xcross/src/shared/update/git_update_ref_resolver.dart': {
    'CLASS:GitUpdateRef': 'internal',
    'CLASS:GitUpdateRefResolver': 'internal',
    'ENUM:GitUpdateRefKind': 'internal',
    'TYPE_ALIAS:CreateTempDirectory': 'internal',
    'TYPE_ALIAS:DeleteDirectory': 'internal',
    'TYPE_ALIAS:RunGitProcess': 'internal',
  },
  'package:xcross/src/shared/update/install_layout.dart': {
    'CLASS:InstallLayout': 'internal',
  },
  'package:xcross/src/shared/update/internal/archive_entry_path.dart': {
    'CLASS:ArchiveEntryPath': 'internal',
  },
  'package:xcross/src/shared/update/internal/dart_executable_resolver.dart': {
    'FUNCTION:findDartExecutableOnPath': 'internal',
  },
  'package:xcross/src/shared/update/internal/file_swap.dart': {
    'CLASS:FileSwap': 'internal',
    'CLASS:StaleBackupCleaner': 'internal',
  },
  'package:xcross/src/shared/update/internal/http_result.dart': {
    'CLASS:HttpResult': 'internal',
  },
  'package:xcross/src/shared/update/internal/release_payload.dart': {
    'CLASS:ReleasePayload': 'internal',
  },
  'package:xcross/src/shared/update/internal/swap_entry.dart': {
    'CLASS:SwapEntry': 'internal',
  },
  'package:xcross/src/shared/update/internal/update_process.dart': {
    'FUNCTION:runUpdateProcess': 'internal',
  },
  'package:xcross/src/shared/update/release_lookup.dart': {
    'CLASS:ReleaseLookup': 'internal',
    'FUNCTION:xcrossAssetBaseUrl': 'internal',
    'TOP_LEVEL_VARIABLE:xcrossRepo': 'internal',
  },
  'package:xcross/src/shared/update/self_update.dart': {
    'CLASS:SelfUpdate': 'internal',
    'TYPE_ALIAS:UpdateVerificationProcess': 'internal',
  },
  'package:xcross/src/shared/update/semver.dart': {
    'CLASS:XcrossSemver': 'internal',
  },
  'package:xcross/src/shared/update/update_check.dart': {
    'CLASS:UpdateCheck': 'internal',
    'CLASS:UpdateCheckCache': 'internal',
  },
  'package:xcross/src/shared/update/update_host_policy.dart': {
    'CLASS:FileSwapOperations': 'internal',
    'CLASS:UpdateHostPolicy': 'internal',
  },
  'package:xcross/src/shared/update/update_progress.dart': {
    'CLASS:UpdatePhases': 'internal',
    'CLASS:UpdateProgress': 'internal',
  },
  'package:xcross/src/shared/xcrun/cross_xcrun.dart': {
    'CLASS:CrossXcrunOperation': 'internal',
    'CLASS:CrossXcrunProbe': 'internal',
    'CLASS:XcrunSdkCommand': 'internal',
    'FUNCTION:_requestedSdk': 'private',
    'FUNCTION:_sdkBaseName': 'private',
    'FUNCTION:_sdkPathProbe': 'private',
    'FUNCTION:_toolIndex': 'private',
    'FUNCTION:_wrapperArguments': 'private',
    'TOP_LEVEL_VARIABLE:_macosxSdk': 'private',
    'TOP_LEVEL_VARIABLE:_probedSdks': 'private',
    'TOP_LEVEL_VARIABLE:_shimTools': 'private',
    'TOP_LEVEL_VARIABLE:xcrunCompatVersion': 'internal',
  },
  'package:xcross/src/shared/xcrun/xcrun_operation.dart': {
    'CLASS:XcrunOperation': 'internal',
    'CLASS:XcrunRuntimeLoader': 'internal',
    'CLASS:XcrunServices': 'internal',
  },
};
