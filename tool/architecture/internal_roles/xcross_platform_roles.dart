import 'package:meta/meta.dart';

@internal
const xcrossPlatformRoles = <String, Map<String, String>>{
  'package:xcross/src/host/linux/sdk/linux_swift_toolchain_host.dart': {
    'CLASS:LinuxSwiftToolchainHost': 'internal',
  },
  'package:xcross/src/host/macos/sdk/macos_swift_toolchain_host.dart': {
    'CLASS:MacOSSwiftToolchainHost': 'internal',
  },
  'package:xcross/src/host/windows/sdk/windows_swift_toolchain_host.dart': {
    'CLASS:WindowsSwiftToolchainHost': 'internal',
    'TOP_LEVEL_VARIABLE:_statusDllNotFound': 'private',
  },
  'package:xcross/src/composition/cli/compose_build_command.dart': {
    'CLASS:ComposeBuildArgs': 'internal',
    'CLASS:ComposeBuildCommand': 'internal',
    r'FUNCTION:_$enumValueHelper': 'private',
    r'FUNCTION:_$parseComposeBuildArgsResult': 'private',
    r'FUNCTION:_$populateComposeBuildArgsParser': 'private',
    'FUNCTION:parseComposeBuildArgs': 'library-internal',
    r'TOP_LEVEL_VARIABLE:_$ComposeConfigurationEnumMapBuildCli': 'private',
    r'TOP_LEVEL_VARIABLE:_$parserForComposeBuildArgs': 'private',
    'TYPE_ALIAS:ComposeCliPackOperation': 'internal',
    'TYPE_ALIAS:ComposeIpaPackage': 'internal',
    'TYPE_ALIAS:ComposeLogDone': 'internal',
  },
  'package:xcross/src/composition/cli/compose_command.dart': {
    'CLASS:ComposeCommand': 'internal',
  },
  'package:xcross/src/composition/cli/compose_run_command.dart': {
    'CLASS:ComposeRunArgs': 'internal',
    'CLASS:ComposeRunCommand': 'internal',
    r'FUNCTION:_$enumValueHelper': 'private',
    r'FUNCTION:_$parseComposeRunArgsResult': 'private',
    r'FUNCTION:_$populateComposeRunArgsParser': 'private',
    'FUNCTION:parseComposeRunArgs': 'library-internal',
    r'TOP_LEVEL_VARIABLE:_$DeviceConnectionEnumMapBuildCli': 'private',
    r'TOP_LEVEL_VARIABLE:_$parserForComposeRunArgs': 'private',
    'TYPE_ALIAS:ComposeRunDevice': 'internal',
  },
  'package:xcross/src/composition/cli/compose_setup_command.dart': {
    'CLASS:ComposeSetupArgs': 'internal',
    'CLASS:ComposeSetupCommand': 'internal',
    r'FUNCTION:_$parseComposeSetupArgsResult': 'private',
    r'FUNCTION:_$populateComposeSetupArgsParser': 'private',
    'FUNCTION:parseComposeSetupArgs': 'library-internal',
    r'TOP_LEVEL_VARIABLE:_$parserForComposeSetupArgs': 'private',
    'TYPE_ALIAS:ComposeSetupEnsure': 'internal',
    'TYPE_ALIAS:ComposeSetupLogDone': 'internal',
    'TYPE_ALIAS:ComposeSetupProblems': 'internal',
  },
  'package:xcross/src/composition/cli/doctor_project_checks.dart': {
    'CLASS:DoctorProjectChecks': 'internal',
  },
  'package:xcross/src/composition/cli/flutter_build_command.dart': {
    'CLASS:CommonFlutterArgs': 'internal',
    'CLASS:FlutterBuildArgs': 'internal',
    'CLASS:FlutterBuildCommand': 'internal',
    r'FUNCTION:_$parseFlutterBuildArgsResult': 'private',
    r'FUNCTION:_$populateFlutterBuildArgsParser': 'private',
    'FUNCTION:parseFlutterBuildArgs': 'library-internal',
    r'TOP_LEVEL_VARIABLE:_$parserForFlutterBuildArgs': 'private',
  },
  'package:xcross/src/composition/cli/flutter_command.dart': {
    'CLASS:FlutterCommand': 'internal',
  },
  'package:xcross/src/composition/cli/flutter_run_command.dart': {
    'CLASS:FlutterRunArgs': 'internal',
    'CLASS:FlutterRunCommand': 'internal',
    r'FUNCTION:_$enumValueHelper': 'private',
    r'FUNCTION:_$parseFlutterRunArgsResult': 'private',
    r'FUNCTION:_$populateFlutterRunArgsParser': 'private',
    'FUNCTION:parseFlutterRunArgs': 'library-internal',
    r'TOP_LEVEL_VARIABLE:_$DeviceConnectionEnumMapBuildCli': 'private',
    r'TOP_LEVEL_VARIABLE:_$parserForFlutterRunArgs': 'private',
  },
  'package:xcross/src/composition/cli/runner.dart': {
    'CLASS:XcrossCli': 'internal',
  },
  'package:xcross/src/composition/flutter/linux_flutter_feature_services.dart':
      {'CLASS:LinuxFlutterFeatureServices': 'internal'},
  'package:xcross/src/composition/flutter/macos_flutter_feature_services.dart':
      {'CLASS:MacOSFlutterFeatureServices': 'internal'},
  'package:xcross/src/composition/flutter/posix_flutter_feature_services.dart':
      {'CLASS:PosixFlutterFeatureServices': 'internal'},
  'package:xcross/src/composition/flutter/swiftpm_checkout.dart': {
    'CLASS:SwiftPmCheckoutAssemblyParts': 'internal',
    'FUNCTION:assembleSwiftPmCheckout': 'internal',
  },
  'package:xcross/src/composition/flutter/swiftpm_foundation.dart': {
    'FUNCTION:prepareSwiftPmFoundation': 'internal',
  },
  'package:xcross/src/composition/flutter/windows_flutter_feature_services.dart':
      {'CLASS:WindowsFlutterFeatureServices': 'internal'},
  'package:xcross/src/composition/host/linux_xcross_context.dart': {
    'CLASS:LinuxXcrossHostContext': 'internal',
  },
  'package:xcross/src/composition/host/macos_xcross_context.dart': {
    'CLASS:MacOSXcrossHostContext': 'internal',
  },
  'package:xcross/src/composition/host/windows_xcross_context.dart': {
    'CLASS:WindowsXcrossHostContext': 'internal',
  },
  'package:xcross/src/composition/host_operations.dart': {
    'FUNCTION:_services': 'private',
    'FUNCTION:linuxHostOperations': 'internal',
    'FUNCTION:macOSHostOperations': 'internal',
    'FUNCTION:windowsHostOperations': 'internal',
  },
  'package:xcross/src/composition/ios_target.dart': {
    'FUNCTION:composeBuildFeatures': 'internal',
    'FUNCTION:composePhysicalFeatures': 'internal',
  },
  'package:xcross/src/composition/native_runtime.dart': {
    'FUNCTION:createNativeXcrossContext': 'internal',
  },
  'package:xcross/src/composition/xcross_application.dart': {
    'CLASS:XcrossApplication': 'internal',
  },
  'package:xcross/src/composition/xcross_host_context.dart': {
    'CLASS:XcrossHostContext': 'internal',
  },
  'package:xcross/src/composition/xcross_runtime.dart': {
    'FUNCTION:composeXcrossHost': 'internal',
  },
  'package:xcross/src/composition/xcrun_sdk.dart': {
    'FUNCTION:parseXcrunSdkName': 'internal',
  },
  'package:xcross/src/host/linux/compose/linux_compose_host.dart': {
    'CLASS:LinuxComposeHost': 'internal',
  },
  'package:xcross/src/host/linux/flutter/native_host_tools.dart': {
    'CLASS:LinuxNativeHostTools': 'internal',
  },
  'package:xcross/src/host/linux/flutter/swiftpm/host_build_services.dart': {
    'CLASS:LinuxSwiftPmHostBuildServices': 'internal',
  },
  'package:xcross/src/host/linux/flutter/swiftpm/swiftpm_host_policy.dart': {
    'CLASS:LinuxSwiftPmHostPolicy': 'internal',
  },
  'package:xcross/src/host/linux/runtime/compose_host_provider.dart': {
    'CLASS:LinuxComposeHostProvider': 'internal',
  },
  'package:xcross/src/host/linux/setup/linux_package_manager.dart': {
    'ENUM:LinuxPackageManager': 'internal',
    'TOP_LEVEL_VARIABLE:_aptPackages': 'private',
    'TOP_LEVEL_VARIABLE:_dnfPackages': 'private',
    'TOP_LEVEL_VARIABLE:_pacmanPackages': 'private',
  },
  'package:xcross/src/host/linux/setup/linux_setup_requirements.dart': {
    'CLASS:LinuxSetupRequirements': 'internal',
  },
  'package:xcross/src/host/linux/update/linux_update_policy.dart': {
    'CLASS:LinuxUpdatePolicy': 'internal',
  },
  'package:xcross/src/host/macos/compose/macos_compose_host.dart': {
    'CLASS:MacOSComposeHost': 'internal',
  },
  'package:xcross/src/host/macos/flutter/native_host_tools.dart': {
    'CLASS:MacOSNativeHostTools': 'internal',
  },
  'package:xcross/src/host/macos/flutter/swiftpm/host_build_services.dart': {
    'CLASS:MacOSSwiftPmHostBuildServices': 'internal',
  },
  'package:xcross/src/host/macos/flutter/swiftpm/swiftpm_host_policy.dart': {
    'CLASS:MacOSSwiftPmHostPolicy': 'internal',
  },
  'package:xcross/src/host/macos/runtime/compose_host_provider.dart': {
    'CLASS:MacOSComposeHostProvider': 'internal',
  },
  'package:xcross/src/host/macos/setup/macos_setup_requirements.dart': {
    'CLASS:MacOSSetupRequirements': 'internal',
  },
  'package:xcross/src/host/macos/target/simulator/compose/macos_compose_simulator_signing.dart':
      {'CLASS:MacOSComposeSimulatorSigning': 'internal'},
  'package:xcross/src/host/macos/target/simulator/runtime/compose_simulator_capability.dart':
      {'CLASS:MacOSComposeSimulatorCapability': 'internal'},
  'package:xcross/src/host/macos/update/macos_update_policy.dart': {
    'CLASS:MacOSUpdatePolicy': 'internal',
  },
  'package:xcross/src/host/macos/xcrun/native_xcrun.dart': {
    'CLASS:NativeMacXcrun': 'internal',
    'TYPE_ALIAS:NativeXcrunStart': 'internal',
  },
  'package:xcross/src/host/shared/cli/native_command_prompt.dart': {
    'CLASS:NativeCommandPrompt': 'internal',
  },
  'package:xcross/src/host/shared/compose/posix_compose_host.dart': {
    'CLASS:PosixComposeHost': 'internal',
    'FUNCTION:isArm64Architecture': 'internal',
    'FUNCTION:isX64Architecture': 'internal',
    'FUNCTION:siblingOrOnPath': 'internal',
  },
  'package:xcross/src/host/shared/config/posix_config_host.dart': {
    'CLASS:PosixConfigHost': 'internal',
  },
  'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer.dart': {
    'CLASS:AppleToolShimRenderer': 'internal',
  },
  'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer_posix.dart':
      {'CLASS:PosixAppleToolShimRenderer': 'internal'},
  'package:xcross/src/host/shared/flutter/apple_tool_shim_templates_posix.dart':
      {
        'FUNCTION:renderUnixCompilerShim': 'internal',
        'FUNCTION:renderUnixOtoolShim': 'internal',
        'FUNCTION:renderUnixToolShim': 'internal',
        'FUNCTION:renderUnixXcrunShim': 'internal',
        'FUNCTION:shellQuote': 'internal',
        'TOP_LEVEL_VARIABLE:unixCodesignShim': 'internal',
      },
  'package:xcross/src/host/shared/flutter/engine_archive_writer.dart': {
    'CLASS:FlutterEngineArchiveWriter': 'internal',
  },
  'package:xcross/src/host/shared/flutter/flutter_sdk_host_policy.dart': {
    'CLASS:FlutterSdkHostPolicy': 'internal',
  },
  'package:xcross/src/host/shared/flutter/native_host_tools.dart': {
    'CLASS:NativeHostTools': 'internal',
    'TYPE_ALIAS:HostCompiler': 'internal',
  },
  'package:xcross/src/host/shared/flutter/posix_flutter_sdk_policy.dart': {
    'CLASS:PosixFlutterSdkPolicy': 'internal',
  },
  'package:xcross/src/host/shared/flutter/swiftpm/artifact_publication_lock.dart':
      {
        'CLASS:FileSwiftPmPublicationLock': 'internal',
        'CLASS:FileSwiftPmPublicationLockProvider': 'internal',
      },
  'package:xcross/src/host/shared/flutter/swiftpm/host_symlink_capability.dart':
      {'CLASS:HostSymlinkCapability': 'internal'},
  'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_copy_policy.dart':
      {'CLASS:PosixSwiftPmArtifactCopyPolicy': 'internal'},
  'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_filesystem.dart':
      {'CLASS:PosixSwiftPmArtifactFileSystem': 'internal'},
  'package:xcross/src/host/shared/flutter/swiftpm/posix_build_execution.dart': {
    'CLASS:PosixSwiftPmBuildExecution': 'internal',
  },
  'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_attributes.dart':
      {'CLASS:PosixSwiftPmCheckoutAttributes': 'internal'},
  'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_link_creator.dart':
      {'CLASS:PosixSwiftPmCheckoutLinkCreator': 'internal'},
  'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_link_policy.dart':
      {
        'CLASS:PosixSwiftPmCheckoutFallback': 'internal',
        'CLASS:PosixSwiftPmCheckoutGitPolicy': 'internal',
      },
  'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_manifest_policy.dart':
      {'CLASS:PosixSwiftPmVendoredManifestPolicy': 'internal'},
  'package:xcross/src/host/shared/flutter/swiftpm/posix_dependency_preparation.dart':
      {'CLASS:PosixSwiftPmDependencyPreparation': 'internal'},
  'package:xcross/src/host/shared/flutter/swiftpm/posix_gate_platform.dart': {
    'CLASS:PosixSwiftPmGatePlatform': 'internal',
  },
  'package:xcross/src/host/shared/flutter/swiftpm/posix_host_build_services.dart':
      {'CLASS:PosixSwiftPmHostBuildServices': 'internal'},
  'package:xcross/src/host/shared/flutter/swiftpm/posix_swiftpm_host_policy.dart':
      {'CLASS:PosixSwiftPmHostPolicy': 'internal'},
  'package:xcross/src/host/shared/runtime/unsupported_compose_simulator_capability.dart':
      {'CLASS:UnsupportedComposeSimulatorCapability': 'internal'},
  'package:xcross/src/host/shared/sdk/preserved_sdk_archive_links.dart': {
    'CLASS:PreservedSdkArchiveLinks': 'internal',
  },
  'package:xcross/src/host/shared/flutter/posix_preview_macro_prologue.dart': {
    r'TOP_LEVEL_VARIABLE:_$posixPreviewMacroPrologue': 'private',
    'TOP_LEVEL_VARIABLE:posixPreviewMacroPrologue': 'internal',
  },
  'package:xcross/src/host/shared/setup/posix_pipx_path.dart': {
    'CLASS:PosixPipxPath': 'internal',
  },
  'package:xcross/src/host/shared/setup/posix_setup_script.dart': {
    'CLASS:PosixSetupScript': 'internal',
  },
  'package:xcross/src/host/shared/tools/unsupported_swiftpm_gate.dart': {
    'CLASS:UnsupportedSwiftPmGate': 'internal',
  },
  'package:xcross/src/host/shared/update/posix_dart_launcher.dart': {
    'CLASS:PosixDartLauncher': 'internal',
  },
  'package:xcross/src/host/shared/update/posix_update_policy.dart': {
    'CLASS:ElevatedFileSwapOperations': 'internal',
    'CLASS:PosixFileSwapOperations': 'internal',
    'FUNCTION:preparePosixUpdate': 'internal',
  },
  'package:xcross/src/host/windows/compose/windows_compose_host.dart': {
    'CLASS:WindowsComposeHost': 'internal',
  },
  'package:xcross/src/host/windows/config/windows_config_host.dart': {
    'CLASS:WindowsConfigHost': 'internal',
  },
  'package:xcross/src/host/windows/flutter/apple_tool_shim_renderer.dart': {
    'CLASS:WindowsAppleToolShimRenderer': 'internal',
  },
  'package:xcross/src/host/windows/flutter/apple_tool_shim_templates.dart': {
    'FUNCTION:powerShellQuote': 'internal',
    'FUNCTION:renderBatchPowerShellShim': 'internal',
    'FUNCTION:renderBatchToolShim': 'internal',
    'FUNCTION:renderPowerShellOtoolShim': 'internal',
    'TOP_LEVEL_VARIABLE:batchCodesignShim': 'internal',
  },
  'package:xcross/src/host/windows/flutter/native_host_tools.dart': {
    'CLASS:WindowsNativeHostTools': 'internal',
    'FUNCTION:missingNativeAssetToolForwarderError': 'internal',
  },
  'package:xcross/src/host/windows/flutter/preview_macro_prologue.dart': {
    r'TOP_LEVEL_VARIABLE:_$windowsPreviewMacroPrologue': 'private',
    'TOP_LEVEL_VARIABLE:windowsPreviewMacroPrologue': 'internal',
  },
  'package:xcross/src/host/windows/flutter/swiftpm/artifact_copy_policy.dart': {
    'CLASS:BinaryCopyDiagnosticCollector': 'internal',
    'CLASS:WindowsSwiftPmArtifactCopyPolicy': 'internal',
  },
  'package:xcross/src/host/windows/flutter/swiftpm/artifact_filesystem.dart': {
    'CLASS:WindowsSwiftPmArtifactFileSystem': 'internal',
    'FUNCTION:isWindowsMountPointReparseOutput': 'internal',
  },
  'package:xcross/src/host/windows/flutter/swiftpm/build_execution.dart': {
    'CLASS:WindowsSwiftPmBuildExecution': 'internal',
  },
  'package:xcross/src/host/windows/flutter/swiftpm/checkout_attributes.dart': {
    'CLASS:WindowsSwiftPmCheckoutAttributes': 'internal',
  },
  'package:xcross/src/host/windows/flutter/swiftpm/checkout_link_creator.dart':
      {
        'CLASS:WindowsSwiftPmCheckoutLinkCreator': 'internal',
        'CLASS:WindowsSwiftPmNativeLinkApi': 'internal',
      },
  'package:xcross/src/host/windows/flutter/swiftpm/checkout_link_policy.dart': {
    'CLASS:WindowsSwiftPmCheckoutFallback': 'internal',
    'CLASS:WindowsSwiftPmCheckoutGitPolicy': 'internal',
  },
  'package:xcross/src/host/windows/flutter/swiftpm/checkout_manifest_policy.dart':
      {'CLASS:WindowsSwiftPmVendoredManifestPolicy': 'internal'},
  'package:xcross/src/host/windows/flutter/swiftpm/dependency_preparation.dart':
      {'CLASS:WindowsSwiftPmDependencyPreparation': 'internal'},
  'package:xcross/src/host/windows/flutter/swiftpm/gate_platform.dart': {
    'CLASS:WindowsSwiftPmGatePlatform': 'internal',
  },
  'package:xcross/src/host/windows/flutter/swiftpm/host_build_services.dart': {
    'CLASS:WindowsSwiftPmHostBuildServices': 'internal',
  },
  'package:xcross/src/host/windows/flutter/swiftpm/pinned_dependency_resolver.dart':
      {'CLASS:WindowsSwiftPmPinnedDependencyResolver': 'internal'},
  'package:xcross/src/host/windows/flutter/swiftpm/swiftpm_host_policy.dart': {
    'CLASS:WindowsSwiftPmHostPolicy': 'internal',
  },
  'package:xcross/src/host/windows/flutter/swiftpm/windows_swift_plan_repair.dart':
      {
        'CLASS:WindowsSwiftPlanRepair': 'internal',
        'TOP_LEVEL_VARIABLE:_clangCompilers': 'private',
        'TOP_LEVEL_VARIABLE:_copyInputAliasDirectoryName': 'private',
        'TOP_LEVEL_VARIABLE:_driveRootPattern': 'private',
        'TOP_LEVEL_VARIABLE:_duplicatedExtendedDrivePrefix': 'private',
        'TOP_LEVEL_VARIABLE:_extendedPathPrefix': 'private',
        'TOP_LEVEL_VARIABLE:_legacyMaxPath': 'private',
        'TOP_LEVEL_VARIABLE:_llbuildArgsPrefix': 'private',
        'TOP_LEVEL_VARIABLE:_maxCommandLineLength': 'private',
        'TOP_LEVEL_VARIABLE:_responseCacheDirectoryName': 'private',
        'TOP_LEVEL_VARIABLE:_responseFileName': 'private',
        'TOP_LEVEL_VARIABLE:_responseFileRetention': 'private',
        'TOP_LEVEL_VARIABLE:_responseFileThreshold': 'private',
        'TOP_LEVEL_VARIABLE:_swiftCompilers': 'private',
      },
  'package:xcross/src/host/windows/flutter/windows_flutter_sdk_policy.dart': {
    'CLASS:WindowsFlutterSdkPolicy': 'internal',
  },
  'package:xcross/src/host/windows/runtime/compose_host_provider.dart': {
    'CLASS:WindowsComposeHostProvider': 'internal',
  },
  'package:xcross/src/host/windows/sdk/materialized_sdk_archive_links.dart': {
    'CLASS:MaterializedSdkArchiveLinks': 'internal',
  },
  'package:xcross/src/host/windows/setup/windows_setup_requirements.dart': {
    'CLASS:WindowsSetupRequirements': 'internal',
  },
  'package:xcross/src/host/windows/setup/windows_setup_script.dart': {
    'CLASS:WindowsSetupScript': 'internal',
  },
  'package:xcross/src/host/windows/tools/windows_swiftpm_gate.dart': {
    'CLASS:WindowsSwiftPmGate': 'internal',
  },
  'package:xcross/src/host/windows/update/windows_update_policy.dart': {
    'CLASS:WindowsFileSwapOperations': 'internal',
    'CLASS:WindowsUpdatePolicy': 'internal',
  },
  'package:xcross/src/host/windows/xcrun/windows_executable.dart': {
    'CLASS:WindowsExecutable': 'internal',
    'FUNCTION:normalizeWindowsExecutableExtension': 'internal',
  },
  'package:xcross/src/target/iphone/cli/basic/tunnel_command.dart': {
    'CLASS:TunnelCommand': 'internal',
  },
  'package:xcross/src/target/iphone/compose/iphone_compose_target.dart': {
    'CLASS:IPhoneComposeTarget': 'internal',
  },
  'package:xcross/src/target/iphone/device/core_device_launch_profile.dart': {
    'CLASS:CoreDeviceLaunchProfile': 'internal',
  },
  'package:xcross/src/target/iphone/device/core_device_launcher.dart': {
    'CLASS:CoreDeviceLauncher': 'internal',
    'TOP_LEVEL_VARIABLE:_cleanupTimeout': 'private',
    'TOP_LEVEL_VARIABLE:_terminateDiscoveryTimeout': 'private',
    'TOP_LEVEL_VARIABLE:_transportCloseTimeout': 'private',
    'TOP_LEVEL_VARIABLE:_vmServiceConnectTimeout': 'private',
    'TOP_LEVEL_VARIABLE:_vmServicePollInterval': 'private',
    'TOP_LEVEL_VARIABLE:_vmServiceWaitTimeout': 'private',
  },
  'package:xcross/src/target/iphone/device/device_backend.dart': {
    'CLASS:DeviceBackend': 'internal',
    'CLASS:NativeBackend': 'internal',
  },
  'package:xcross/src/target/iphone/device/device_log.dart': {
    'CLASS:DeviceLog': 'internal',
  },
  'package:xcross/src/target/iphone/device/device_run_operation.dart': {
    'CLASS:DeviceRunOperation': 'internal',
    'TYPE_ALIAS:LaunchInstalledApp': 'internal',
    'TYPE_ALIAS:OsMajorVersion': 'internal',
    'TYPE_ALIAS:TerminateInstalledApp': 'internal',
  },
  'package:xcross/src/target/iphone/device/internal/signed_bundle_identity.dart':
      {'CLASS:SignedBundleIdentity': 'internal'},
  'package:xcross/src/target/iphone/device/session_console.dart': {
    'CLASS:SessionConsole': 'internal',
  },
  'package:xcross/src/target/iphone/device/signed_bundle_preparer.dart': {
    'CLASS:SignedBundlePreparer': 'internal',
  },
  'package:xcross/src/target/iphone/device/signing_http_client_factory.dart': {
    'CLASS:HttpSigningClientFactory': 'internal',
  },
  'package:xcross/src/target/iphone/device/signing_session_resolver.dart': {
    'CLASS:SigningSessionProvider': 'internal',
    'CLASS:SigningSessionResolver': 'internal',
  },
  'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart': {
    'CLASS:IPhoneFlutterTarget': 'internal',
  },
  'package:xcross/src/target/iphone/runtime/build_features.dart': {
    'CLASS:IPhoneBuildFeatures': 'internal',
  },
  'package:xcross/src/target/iphone/sdk/iphone_sdk_metadata_platform.dart': {
    'CLASS:IPhoneSdkMetadataPlatform': 'internal',
  },
  'package:xcross/src/target/shared/compose/compose_target.dart': {
    'CLASS:BaseComposeTarget': 'internal',
    'CLASS:ComposeTarget': 'internal',
    'FUNCTION:deviceResourceFallbacks': 'internal',
    'FUNCTION:isDeviceResourceTarget': 'internal',
    'FUNCTION:primaryResourceCandidates': 'internal',
  },
  'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart': {
    'CLASS:FlutterTargetBuildPolicy': 'internal',
    'FUNCTION:selectFlutterEngineSlice': 'internal',
  },
  'package:xcross/src/target/shared/flutter/ios_plist_metadata.dart': {
    'CLASS:IosPlistMetadata': 'internal',
  },
  'package:xcross/src/target/shared/runtime/build_features.dart': {
    'CLASS:XcrossBuildFeatures': 'internal',
  },
  'package:xcross/src/target/simulator/compose/simulator_compose_target.dart': {
    'CLASS:SimulatorComposeTarget': 'internal',
  },
  'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart': {
    'CLASS:SimulatorFlutterTarget': 'internal',
  },
  'package:xcross/src/target/simulator/runtime/build_features.dart': {
    'CLASS:SimulatorBuildFeatures': 'internal',
  },
  'package:xcross/src/target/simulator/sdk/simulator_sdk_metadata_platform.dart':
      {'CLASS:SimulatorSdkMetadataPlatform': 'internal'},
};
