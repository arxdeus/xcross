import 'package:meta/meta.dart';

@internal
const xcrossApplicationTestsRoles = <String, Map<String, String>>{
  'workspace:packages/xcross/test/apple/arm64_instructions_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/auth_adi_test.dart': {
    'CLASS:ClosingAuthApkClient': 'internal',
    'FUNCTION:_apkBytes': 'private',
    'FUNCTION:_libraryBytes': 'private',
    'FUNCTION:_writeLibraries': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/auth_clear_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/auth_fixture.dart': {
    'CLASS:AuthNamespaceFileSystem': 'internal',
    'CLASS:AuthNamespaceFixture': 'internal',
    'CLASS:AuthNamespaceHost': 'internal',
    'CLASS:AuthNamespaceIdentity': 'internal',
    'CLASS:AuthNamespacePaths': 'internal',
    'CLASS:AuthNamespacePermissions': 'internal',
    'FUNCTION:authFixture': 'internal',
  },
  'workspace:packages/xcross/test/cli/clean_command_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/compose_command_args_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/config_command_test.dart': {
    'CLASS:FakeTerminal': 'internal',
    'FUNCTION:handle': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/doctor_command_test.dart': {
    'CLASS:DoctorNamespaceDiagnostics': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/doctor_environment_checks_test.dart': {
    'CLASS:DoctorServiceDevices': 'internal',
    'CLASS:DoctorServiceFileSystem': 'internal',
    'CLASS:DoctorServiceFixture': 'internal',
    'CLASS:DoctorServiceHost': 'internal',
    'CLASS:DoctorServiceLocations': 'internal',
    'CLASS:DoctorServiceLookup': 'internal',
    'CLASS:DoctorServiceProcess': 'internal',
    'CLASS:DoctorServiceProcesses': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/flutter_command_args_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/ide_command_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/ipa_packager_test.dart': {
    'FUNCTION:_bytesFrom': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/native_command_prompt_test.dart': {
    'CLASS:PromptTestInput': 'internal',
    'CLASS:PromptTestSink': 'internal',
    'FUNCTION:main': 'entrypoint',
    'FUNCTION:promptError': 'internal',
  },
  'workspace:packages/xcross/test/cli/runtime_composition_test.dart': {
    'CLASS:FailingDeviceDiagnostics': 'internal',
    'CLASS:RecordingDevicePreparation': 'internal',
    'CLASS:RecordingGuardPrompt': 'internal',
    'CLASS:RecordingSimulatorSigning': 'internal',
    'CLASS:RecordingTunnelAvailability': 'internal',
    'FUNCTION:copyRuntime': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/runtime_fixture.dart': {
    'CLASS:TestCommandPrompt': 'internal',
    'CLASS:TestDeviceConsole': 'internal',
    'CLASS:TestDeviceSockets': 'internal',
    'CLASS:TestTerminal': 'internal',
    'FUNCTION:testApplication': 'internal',
    'FUNCTION:testRuntime': 'internal',
  },
  'workspace:packages/xcross/test/cli/sdk_archive_safety_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/sdk_command_test.dart': {
    'CLASS:SdkCommandTestIo': 'internal',
    'CLASS:WindowsSdkStageDirectoryFixture': 'internal',
    'CLASS:WindowsSdkStageFileSystemFixture': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/sdk_file_system_inspection_test.dart': {
    'CLASS:MappedSdkInspectionDirectory': 'internal',
    'CLASS:MappedSdkInspectionFile': 'internal',
    'CLASS:MappedSdkInspectionFileSystem': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/sdk_metadata_test.dart': {
    'CLASS:SdkMetadataTestIo': 'internal',
    'CLASS:WindowsSdkMetadataFileSystemFixture': 'internal',
    'CLASS:WindowsSdkMetadataPlatformFixture': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/sdk_platform_layout_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/sdk_tbd_link_test.dart': {
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_bundleSdk': 'private',
    'TOP_LEVEL_VARIABLE:_sdkRoot': 'private',
  },
  'workspace:packages/xcross/test/cli/sdk_tbd_patch_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/sdk_test_support.dart': {
    'CLASS:SdkFixtureLogOutput': 'internal',
    'CLASS:SdkTestContext': 'internal',
  },
  'workspace:packages/xcross/test/cli/sdk_toolchain_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/sdk_xcode_import_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/swift_requirement_test.dart': {
    'FUNCTION:_requireSwift': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/tool_alias_dispatch_test.dart': {
    'FUNCTION:main': 'entrypoint',
    'FUNCTION:windowsAliasRunner': 'internal',
  },
  'workspace:packages/xcross/test/cli/update_command_test.dart': {
    'FUNCTION:_captureAsync': 'private',
    'FUNCTION:_run': 'private',
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_layout': 'private',
    'TOP_LEVEL_VARIABLE:_shaA': 'private',
    'TOP_LEVEL_VARIABLE:_shaB': 'private',
    'TOP_LEVEL_VARIABLE:_shaC': 'private',
  },
  'workspace:packages/xcross/test/cli/xcode_swift_requirement_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/cli/xcrun_test.dart': {
    'CLASS:FixtureNativeChild': 'internal',
    'CLASS:FixtureNativeProcesses': 'internal',
    'CLASS:FixtureProbeOutput': 'internal',
    'CLASS:FixtureUnusedLoader': 'internal',
    'FUNCTION:_fixtureTarget': 'private',
    'FUNCTION:_requestedSdkForFixture': 'private',
    'FUNCTION:_runXcrun': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/config/config_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/config/runtime_config_test.dart': {
    'CLASS:ConfigFixtureFileSystem': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/dap/dap_child_controller_test.dart': {
    'CLASS:FakeDapChild': 'internal',
    'CLASS:RecordingDapProcesses': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/dap/dap_router_test.dart': {
    'CLASS:TestAdapterChild': 'internal',
    'CLASS:TestAdapterProcesses': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/dap/tunnel_availability_test.dart': {
    'CLASS:AvailabilityChild': 'internal',
    'CLASS:AvailabilityProcesses': 'internal',
    'CLASS:DapFixtureFileSystem': 'internal',
    'CLASS:FakeTunnelAvailability': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/device/app_entitlements_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/device/core_device_launch_profile_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/device/core_device_launcher_bundle_id_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/xcross/test/device/device_backend_test.dart': {
    'CLASS:NoIoAnisetteProvider': 'internal',
    'FUNCTION:_session': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/device/device_log_crash_reason_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/device/device_run_operation_test.dart': {
    'CLASS:FakeDeviceBackend': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/device/native_backend_lifecycle_test.dart': {
    'CLASS:CountingAnisetteProvider': 'internal',
    'CLASS:FailingProvisioningClient': 'internal',
    'CLASS:FixedSigningSessionProvider': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/device/session_console_restart_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/device/session_console_stop_test.dart': {
    'FUNCTION:_frame': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/device/signed_bundle_identity_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/device/test_log_output.dart': {
    'CLASS:TestDeviceConsole': 'internal',
    'CLASS:TestLogOutput': 'internal',
    'FUNCTION:testLocalHttp': 'internal',
    'FUNCTION:testLog': 'internal',
    'FUNCTION:testSink': 'internal',
  },
  'workspace:packages/xcross/test/host_operations_fixtures.dart': {
    'CLASS:FixtureIOSink': 'internal',
    'CLASS:FixtureLogOutput': 'internal',
    'CLASS:FixtureMappedFileSystem': 'internal',
    'CLASS:FixturePrivileges': 'internal',
    'FUNCTION:fixtureLog': 'internal',
    'FUNCTION:fixtureRunner': 'internal',
    'FUNCTION:fixtureSink': 'internal',
  },
  'workspace:packages/xcross/test/import_boundary_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/log_fixture.dart': {
    'CLASS:TestByteConsumer': 'internal',
    'CLASS:TestLogOutput': 'internal',
    'FUNCTION:testByteSink': 'internal',
    'FUNCTION:testLog': 'internal',
  },
  'workspace:packages/xcross/test/no_deep_imports_test.dart': {
    'FUNCTION:deepImportViolations': 'internal',
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_packages': 'private',
    'TOP_LEVEL_VARIABLE:_repoRoot': 'private',
  },
  'workspace:packages/xcross/test/package_config_resolver_test.dart': {
    'CLASS:PackageConfigMappedFileSystem': 'internal',
    'FUNCTION:_readXcrossSource': 'private',
    'FUNCTION:_writePackageConfig': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/release_packaging_test.dart': {
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_repoRoot': 'private',
  },
  'workspace:packages/xcross/test/setup/clang_requirement_test.dart': {
    'FUNCTION:_resolveClang': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/setup/host_ops_residual_fixtures.dart': {
    'CLASS:ResidualChild': 'internal',
    'CLASS:ResidualFileSystem': 'internal',
    'CLASS:ResidualHost': 'internal',
    'CLASS:ResidualLookup': 'internal',
    'CLASS:ResidualPaths': 'internal',
    'CLASS:ResidualProcesses': 'internal',
    'FUNCTION:residualProcessHost': 'internal',
    'FUNCTION:residualRunner': 'internal',
  },
  'workspace:packages/xcross/test/setup/host_ops_residual_test.dart': {
    'CLASS:ResidualFailingSetupPolicy': 'internal',
    'CLASS:ResidualHttpClient': 'internal',
    'CLASS:ResidualHttpRequest': 'internal',
    'CLASS:ResidualHttpResponse': 'internal',
    'CLASS:ResidualMappedPaths': 'internal',
    'CLASS:ResidualToolchainLocations': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/setup/host_requirements_test.dart': {
    'CLASS:FixtureChild': 'internal',
    'CLASS:FixtureInput': 'internal',
    'CLASS:FixtureLocations': 'internal',
    'CLASS:FixturePrivileges': 'internal',
    'CLASS:FixtureProcesses': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/setup/setup_script_test.dart': {
    'CLASS:FixtureSetupHttpClient': 'internal',
    'CLASS:FixtureSharingFailure': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/archive_entry_path_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/build_xcross_test.dart': {
    'CLASS:FixtureBuildChild': 'internal',
    'CLASS:FixtureBuildProcesses': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/checksums_test.dart': {
    'FUNCTION:_realDigest': 'private',
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_payload': 'private',
    'TOP_LEVEL_VARIABLE:_payloadDigest': 'private',
  },
  'workspace:packages/xcross/test/update/dart_executable_resolver_test.dart': {
    'FUNCTION:_createBinDirectory': 'private',
    'FUNCTION:_isRoot': 'private',
    'FUNCTION:_linuxEnvironment': 'private',
    'FUNCTION:_windowsEnvironment': 'private',
    'FUNCTION:_windowsRunner': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/file_swap_fixtures.dart': {
    'CLASS:FixtureRemappedOperations': 'internal',
  },
  'workspace:packages/xcross/test/update/file_swap_test.dart': {
    'CLASS:FixtureMappedWindowsOperations': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/git_ref_source_bundle_builder_test.dart':
      {
        'CLASS:FixtureFakeProcessRunner': 'internal',
        'CLASS:FixtureProcessCall': 'internal',
        'FUNCTION:_captureAsync': 'private',
        'FUNCTION:_createBundle': 'private',
        'FUNCTION:_createScratchDirectory': 'private',
        'FUNCTION:_createTestBuilder': 'private',
        'FUNCTION:_deleteDirectorySync': 'private',
        'FUNCTION:_listEquals': 'private',
        'FUNCTION:_result': 'private',
        'FUNCTION:main': 'entrypoint',
        'TOP_LEVEL_VARIABLE:_fakeDartExecutable': 'private',
      },
  'workspace:packages/xcross/test/update/git_update_ref_resolver_test.dart': {
    'CLASS:FixtureFakeGitRunner': 'internal',
    'CLASS:FixtureFakeTempDirectories': 'internal',
    'CLASS:FixtureGitCall': 'internal',
    'FUNCTION:_result': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/install_layout_test.dart': {
    'FUNCTION:_exeName': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/release_http_fixtures.dart': {
    'CLASS:FixtureReleaseHttpClient': 'internal',
    'CLASS:FixtureReleaseHttpHeaders': 'internal',
    'CLASS:FixtureReleaseHttpRequest': 'internal',
    'CLASS:FixtureReleaseHttpResponse': 'internal',
  },
  'workspace:packages/xcross/test/update/release_lookup_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/release_payload_test.dart': {
    'FUNCTION:_bundle': 'private',
    'FUNCTION:_entry': 'private',
    'FUNCTION:_tarGz': 'private',
    'FUNCTION:_zip': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/self_update_test.dart': {
    'FUNCTION:_captureAsync': 'private',
    'FUNCTION:_configuredUpdater': 'private',
    'FUNCTION:_exeName': 'private',
    'FUNCTION:_installBundle': 'private',
    'FUNCTION:_verifyInstalledBinary': 'private',
    'FUNCTION:main': 'entrypoint',
    'TYPE_ALIAS:_RunRequest': 'private',
  },
  'workspace:packages/xcross/test/update/semver_test.dart': {
    'FUNCTION:_parse': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/swiftpm_gate_tool_test.dart': {
    'CLASS:FixtureLoader': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/update_check_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/update_process_test.dart': {
    'CLASS:FixtureLineCaptureStdout': 'internal',
    'FUNCTION:_captureAsync': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/update/update_progress_test.dart': {
    'FUNCTION:_captureAsync': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/xcross/test/version_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
};
