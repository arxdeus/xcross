import 'package:meta/meta.dart';

@internal
const supportPackagesRoles = <String, Map<String, String>>{
  'package:cli_kit/composition/native_host.dart': {
    'CLASS:NativeHostSnapshot': 'public',
    'FUNCTION:detectPlatformHost': 'public',
    'FUNCTION:detectPlatformHostSnapshot': 'public',
  },
  'package:cli_kit/host/linux/linux_host.dart': {'CLASS:LinuxHost': 'public'},
  'package:cli_kit/host/macos/macos_host.dart': {'CLASS:MacOSHost': 'public'},
  'package:cli_kit/host/shared/io_tui_terminal.dart': {
    'CLASS:IoTuiTerminal': 'public',
  },
  'package:cli_kit/host/shared/posix_paths.dart': {
    'CLASS:PosixPaths': 'public',
  },
  'package:cli_kit/host/shared/posix_privileges.dart': {
    'CLASS:PosixPrivileges': 'public',
  },
  'package:cli_kit/host/windows/windows_host.dart': {
    'CLASS:WindowsHost': 'public',
  },
  'package:cli_kit/host/windows/windows_paths.dart': {
    'CLASS:WindowsPaths': 'public',
  },
  'package:cli_kit/host/windows/windows_privileges.dart': {
    'CLASS:WindowsPrivileges': 'public',
  },
  'package:cli_kit/shared/download/download.dart': {
    'CLASS:Downloader': 'public',
  },
  'package:cli_kit/shared/errors/errors.dart': {'CLASS:CliError': 'public'},
  'package:cli_kit/shared/http/local_http.dart': {'CLASS:LocalHttp': 'public'},
  'package:cli_kit/shared/logging/logging.dart': {
    'CLASS:Glyph': 'public',
    'CLASS:Log': 'public',
    'CLASS:LogOutput': 'public',
    'CLASS:Step': 'public',
    'CLASS:StreamLogOutput': 'public',
  },
  'package:cli_kit/shared/platform/file_system_inspection.dart': {
    'EXTENSION:HostFileSystemInspection': 'public',
  },
  'package:cli_kit/shared/platform/platform_host.dart': {
    'CLASS:HostEnvironmentInterface': 'public',
    'CLASS:HostFileSystemInterface': 'public',
    'CLASS:HostPathsInterface': 'public',
    'CLASS:HostPermissionsInterface': 'public',
    'CLASS:HostPrivilegesInterface': 'public',
    'CLASS:HostProcessInterface': 'public',
    'CLASS:LinuxHostInterface': 'public',
    'CLASS:MacOSHostInterface': 'public',
    'CLASS:PlatformHostInterface': 'public',
    'CLASS:WindowsHostInterface': 'public',
  },
  'package:cli_kit/shared/process/process.dart': {
    'CLASS:ProcessRunner': 'public',
  },
  'package:cli_kit/shared/process/process_executor.dart': {
    'CLASS:ProcessExecutor': 'public',
  },
  'package:cli_kit/shared/process/process_models.dart': {
    'CLASS:CapturedProcess': 'public',
    'CLASS:ProcessConfiguration': 'public',
  },
  'package:cli_kit/shared/process/tool_lookup.dart': {
    'CLASS:ProcessToolLookup': 'public',
    'CLASS:ProcessToolLookupInterface': 'public',
  },
  'package:cli_kit/shared/progress/progress.dart': {
    'CLASS:ProgressBar': 'public',
    'ENUM:ProgressUnit': 'public',
  },
  'package:cli_kit/shared/tui/tui.dart': {
    'CLASS:AnsiTui': 'public',
    'CLASS:AnsiTuiRenderer': 'public',
    'CLASS:AnsiTuiStyle': 'public',
    'CLASS:TuiTerminal': 'public',
    'ENUM:TuiKey': 'public',
  },
  'package:cli_kit/src/host/linux/linux_permissions.dart': {
    'CLASS:LinuxPermissions': 'internal',
  },
  'package:cli_kit/src/host/macos/macos_permissions.dart': {
    'CLASS:MacOSPermissions': 'internal',
  },
  'package:cli_kit/src/host/shared/native_file_system.dart': {
    'CLASS:NativeFileSystem': 'internal',
  },
  'package:cli_kit/src/host/shared/native_tool_lookup.dart': {
    'FUNCTION:locateNativeCleanupTool': 'internal',
  },
  'package:cli_kit/src/host/shared/owned_processes.dart': {
    'CLASS:OwnedProcesses': 'internal',
  },
  'package:cli_kit/src/host/shared/posix_environment.dart': {
    'CLASS:PosixEnvironment': 'internal',
  },
  'package:cli_kit/src/host/shared/posix_processes.dart': {
    'CLASS:PosixProcesses': 'internal',
  },
  'package:cli_kit/src/host/windows/windows_batch.dart': {
    'CLASS:WindowsBatchPolicy': 'internal',
  },
  'package:cli_kit/src/host/windows/windows_environment.dart': {
    'CLASS:WindowsEnvironment': 'internal',
  },
  'package:cli_kit/src/host/windows/windows_file_system.dart': {
    'CLASS:WindowsFileSystem': 'internal',
  },
  'package:cli_kit/src/host/windows/windows_processes.dart': {
    'CLASS:WindowsProcesses': 'internal',
  },
  'package:cli_kit/src/shared/platform/permission_mode.dart': {
    'FUNCTION:octalPermissionMode': 'internal',
  },
  'package:cli_kit/src/shared/process/process_helpers.dart': {
    'CLASS:ProcessHelpers': 'internal',
  },
  'package:cli_kit/target/shared/platform_target.dart': {
    'CLASS:PlatformTargetInterface': 'public',
  },
  'package:dart_mobile_device/host/linux/linux_device_host.dart': {
    'CLASS:LinuxDeviceHost': 'public',
  },
  'package:dart_mobile_device/host/macos/macos_device_host.dart': {
    'CLASS:MacOSDeviceHost': 'public',
  },
  'package:dart_mobile_device/host/shared/console/native_device_console.dart': {
    'CLASS:NativeDeviceConsole': 'public',
  },
  'package:dart_mobile_device/host/shared/network/native_device_sockets.dart': {
    'CLASS:NativeDeviceSockets': 'public',
  },
  'package:dart_mobile_device/host/shared/posix_device_host.dart': {
    'CLASS:PosixDeviceHost': 'public',
  },
  'package:dart_mobile_device/host/windows/windows_device_host.dart': {
    'CLASS:WindowsDeviceHost': 'public',
  },
  'package:dart_mobile_device/shared/console/device_console.dart': {
    'CLASS:DeviceConsole': 'public',
  },
  'package:dart_mobile_device/shared/device/gdb_remote_client.dart': {
    'CLASS:GdbRemoteClient': 'public',
    'CLASS:GdbReplyPacket': 'public',
    'ENUM:GdbReply': 'public',
  },
  'package:dart_mobile_device/shared/device/models/device.dart': {
    'CLASS:Device': 'public',
    'ENUM:ConnectionType': 'public',
    'ENUM:DeviceSearchMode': 'public',
    'ENUM:DeviceSource': 'public',
  },
  'package:dart_mobile_device/shared/device/models/device_endpoint.dart': {
    'CLASS:DeviceEndpoint': 'public',
  },
  'package:dart_mobile_device/shared/device/transport/device_transport.dart': {
    'CLASS:DeviceTransport': 'public',
  },
  'package:dart_mobile_device/shared/device/tunnel/port_forwarder.dart': {
    'CLASS:PortForwarder': 'public',
  },
  'package:dart_mobile_device/shared/diagnostics/device_probe.dart': {
    'CLASS:DeviceDiagnostics': 'public',
  },
  'package:dart_mobile_device/shared/errors/errors.dart': {
    'CLASS:TunnelCreationError': 'public',
    'CLASS:TunnelError': 'public',
    'CLASS:TunnelPrivilegeError': 'public',
  },
  'package:dart_mobile_device/shared/host/device_host_policy.dart': {
    'CLASS:DeviceHostPolicy': 'public',
  },
  'package:dart_mobile_device/shared/network/device_sockets.dart': {
    'CLASS:DeviceSockets': 'public',
  },
  'package:dart_mobile_device/shared/preparation/device_preparation.dart': {
    'CLASS:DevicePreparation': 'public',
  },
  'package:dart_mobile_device/shared/tunnel/tunnel_availability.dart': {
    'CLASS:TunnelAvailability': 'public',
  },
  'package:dart_mobile_device/src/host/shared/target/iphone/device/lockdown_tunnel_controller.dart':
      {'CLASS:LockdownTunnelController': 'internal'},
  'package:dart_mobile_device/src/host/shared/tunnel/tunnel_process_controller.dart':
      {'CLASS:TunnelProcessController': 'internal'},
  'package:dart_mobile_device/src/shared/device/models/tunnel.dart': {
    'CLASS:Tunnel': 'internal',
  },
  'package:dart_mobile_device/src/shared/device/transport/internal/device_transport_mode.dart':
      {'ENUM:DeviceTransportMode': 'internal'},
  'package:dart_mobile_device/src/shared/preparation/tunnel_failure_guidance.dart':
      {'FUNCTION:describeDeviceTunnelFailure': 'internal'},
  'package:dart_mobile_device/src/target/iphone/device/pymd/remote_pairing.dart':
      {'CLASS:RemotePairing': 'internal'},
  'package:dart_mobile_device/src/target/iphone/device/tunnel/kernel_tunnel_transport.dart':
      {'CLASS:KernelTunnelTransport': 'internal'},
  'package:dart_mobile_device/src/target/iphone/device/tunnel/tunnel_daemon.dart':
      {'CLASS:TunnelDaemon': 'internal', 'CLASS:TunneldLogTail': 'internal'},
  'package:dart_mobile_device/src/target/iphone/device/tunnel/tunnel_discovery.dart':
      {'CLASS:TunnelDiscovery': 'internal'},
  'package:dart_mobile_device/src/target/iphone/device/tunnel/userspace_tunnel_transport.dart':
      {'CLASS:UserspaceTunnelTransport': 'internal'},
  'package:dart_mobile_device/src/target/iphone/preparation/developer_disk_image.dart':
      {'CLASS:DeveloperDiskImage': 'internal'},
  'package:dart_mobile_device/src/target/iphone/preparation/wireless_device_preparation.dart':
      {
        'CLASS:WirelessDevicePreparation': 'internal',
        'CLASS:WirelessWaitDiagnostics': 'internal',
        'ENUM:WirelessBootstrapPath': 'internal',
      },
  'package:dart_mobile_device/target/iphone/device/constants.dart': {
    'CLASS:TunnelConstants': 'public',
  },
  'package:dart_mobile_device/target/iphone/device/device_prepare.dart': {
    'CLASS:DevicePrepare': 'public',
  },
  'package:dart_mobile_device/target/iphone/device/os_version.dart': {
    'CLASS:OsVersion': 'public',
  },
  'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart': {
    'CLASS:Pymd': 'public',
    'CLASS:PymdInvocation': 'public',
    'CLASS:TunneldInvocation': 'public',
  },
  'package:dart_mobile_device/target/iphone/device/pymd/pymd_device_resolver.dart':
      {'CLASS:PymdDeviceResolver': 'public'},
  'package:dart_mobile_device/target/iphone/device/pymd/pymd_devices.dart': {
    'CLASS:PymdDevices': 'public',
  },
  'package:dart_mobile_device/target/iphone/device/transport/device_transport_resolver.dart':
      {'CLASS:DeviceTransportResolver': 'public'},
  'package:dart_mobile_device/target/iphone/diagnostics/pymd_device_diagnostics.dart':
      {'CLASS:PymdDeviceDiagnostics': 'public'},
  'package:dart_mobile_device/target/iphone/tunnel/pymd_tunnel_availability.dart':
      {'CLASS:PymdTunnelAvailability': 'public'},
  'package:darwin_sdk_kit/host/linux/linux_darwin_toolchain_locations.dart': {
    'CLASS:LinuxDarwinToolchainLocations': 'public',
  },
  'package:darwin_sdk_kit/host/macos/macos_darwin_toolchain_locations.dart': {
    'CLASS:MacOSDarwinToolchainLocations': 'public',
  },
  'package:darwin_sdk_kit/host/shared/darwin_toolchain_locations.dart': {
    'CLASS:DarwinToolchainLocationsInterface': 'public',
  },
  'package:darwin_sdk_kit/host/windows/windows_darwin_toolchain_locations.dart':
      {'CLASS:WindowsDarwinToolchainLocations': 'public'},
  'package:darwin_sdk_kit/shared/archive/cpio_reader.dart': {
    'CLASS:CpioEntry': 'public',
    'CLASS:CpioReader': 'public',
    'TOP_LEVEL_VARIABLE:_devOffset': 'private',
    'TOP_LEVEL_VARIABLE:_filesizeOffset': 'private',
    'TOP_LEVEL_VARIABLE:_headerSize': 'private',
    'TOP_LEVEL_VARIABLE:_inoOffset': 'private',
    'TOP_LEVEL_VARIABLE:_modeOffset': 'private',
    'TOP_LEVEL_VARIABLE:_namesizeOffset': 'private',
    'TOP_LEVEL_VARIABLE:_nlinkOffset': 'private',
    'TOP_LEVEL_VARIABLE:_odcMagic': 'private',
    'TOP_LEVEL_VARIABLE:_trailerName': 'private',
  },
  'package:darwin_sdk_kit/shared/archive/xcode_xip_extractor.dart': {
    'CLASS:XcodeXipExtractor': 'public',
  },
  'package:darwin_sdk_kit/shared/errors/errors.dart': {
    'CLASS:DarwinSdkError': 'public',
  },
  'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart': {
    'CLASS:DarwinSdk': 'public',
  },
  'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart': {
    'CLASS:DarwinSdkRepository': 'public',
  },
  'package:darwin_sdk_kit/shared/tbd/tbd_architecture_rewrite.dart': {
    'TOP_LEVEL_VARIABLE:tbdArchitectureAliases': 'public',
  },
  'package:darwin_sdk_kit/shared/tbd/tbd_bundle_patch.dart': {
    'CLASS:TbdBundlePatch': 'public',
    'CLASS:TbdPatchResult': 'public',
  },
  'package:darwin_sdk_kit/shared/tbd/tbd_linker_diagnostic.dart': {
    'CLASS:TbdLinkerDiagnostic': 'public',
  },
  'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart': {
    'CLASS:DarwinToolchainResolver': 'public',
  },
  'package:darwin_sdk_kit/src/shared/archive/internal/byte_cursor.dart': {
    'CLASS:ByteCursor': 'internal',
  },
  'package:darwin_sdk_kit/src/shared/archive/pbzx_reader.dart': {
    'CLASS:PbzxReader': 'internal',
    'TOP_LEVEL_VARIABLE:_lzma2UncompressedNoReset': 'private',
    'TOP_LEVEL_VARIABLE:_lzma2UncompressedReset': 'private',
    'TOP_LEVEL_VARIABLE:_pbzxChunkSize': 'private',
    'TOP_LEVEL_VARIABLE:_xzMagic': 'private',
    'TOP_LEVEL_VARIABLE:_xzStreamHeaderSize': 'private',
  },
  'package:darwin_sdk_kit/src/shared/archive/xar_reader.dart': {
    'CLASS:XarEntry': 'internal',
    'CLASS:XarReader': 'internal',
    'TOP_LEVEL_VARIABLE:_headerPrefixSize': 'private',
    'TOP_LEVEL_VARIABLE:_headerSizeOffset': 'private',
    'TOP_LEVEL_VARIABLE:_tocLengthCompressedOffset': 'private',
    'TOP_LEVEL_VARIABLE:_xarMagic': 'private',
  },
  'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart': {
    'CLASS:IPhoneBuildPlatform': 'public',
  },
  'package:darwin_sdk_kit/target/iphone/iphone_target.dart': {
    'CLASS:IPhoneTarget': 'public',
  },
  'package:darwin_sdk_kit/target/shared/ios_build_platform.dart': {
    'CLASS:IosBuildPlatformInterface': 'public',
  },
  'package:darwin_sdk_kit/target/shared/ios_target.dart': {
    'CLASS:IPhoneTargetInterface': 'public',
    'CLASS:IosTarget': 'public',
    'CLASS:SimulatorTargetInterface': 'public',
  },
  'package:darwin_sdk_kit/target/simulator/simulator_build_platform.dart': {
    'CLASS:SimulatorBuildPlatform': 'public',
  },
  'package:darwin_sdk_kit/target/simulator/simulator_target.dart': {
    'CLASS:SimulatorTarget': 'public',
  },
  'package:frontend_server_kit/host/shared/process/host_compiler_process_factory.dart':
      {'CLASS:HostCompilerProcessFactory': 'public'},
  'package:frontend_server_kit/shared/compiler/frontend_server_options.dart': {
    'CLASS:FrontendServerOptions': 'public',
  },
  'package:frontend_server_kit/shared/compiler/frontend_server_session.dart': {
    'CLASS:FrontendServerSession': 'public',
  },
  'package:frontend_server_kit/shared/compiler/package_uris.dart': {
    'CLASS:PackageUriLoader': 'public',
    'CLASS:PackageUris': 'public',
  },
  'package:frontend_server_kit/shared/errors/errors.dart': {
    'CLASS:FrontendServerException': 'public',
  },
  'package:frontend_server_kit/shared/process/compiler_transport.dart': {
    'CLASS:CompilerProcessFactory': 'public',
    'CLASS:CompilerTransport': 'public',
  },
  'workspace:packages/cli_kit/test/download_test.dart': {
    'CLASS:DownloadTestClient': 'internal',
    'CLASS:DownloadTestRequest': 'internal',
    'CLASS:DownloadTestResponse': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/file_system_inspection_test.dart': {
    'CLASS:FailingInspectionFile': 'internal',
    'CLASS:FailingInspectionFileSystem': 'internal',
    'CLASS:InspectionFileSystem': 'internal',
    'CLASS:InspectionLink': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/host_context_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/host_paths_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/host_permissions_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/host_privileges_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/local_http_test.dart': {
    'CLASS:RecordingHttpClient': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/logging_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/platform_host_test.dart': {
    'CLASS:RecordingProcesses': 'internal',
    'CLASS:UnownedTestProcess': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/process_io_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/process_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/process_timeout_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/progress_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/run_tool_test.dart': {
    'FUNCTION:_capture': 'private',
    'FUNCTION:_captureAsync': 'private',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/shared_stdin_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/cli_kit/test/support/log_output.dart': {
    'CLASS:RecordingLogOutput': 'internal',
    'CLASS:ThrowingLogOutput': 'internal',
  },
  'workspace:packages/cli_kit/test/support/test_log_output.dart': {
    'CLASS:TestLogOutput': 'internal',
  },
  'workspace:packages/cli_kit/test/support/test_process_io.dart': {
    'CLASS:TestProcessIo': 'internal',
  },
  'workspace:packages/cli_kit/test/tui_test.dart': {
    'CLASS:FakeTerminal': 'internal',
    'FUNCTION:main': 'entrypoint',
    'FUNCTION:stripAnsi': 'internal',
  },
  'workspace:packages/cli_kit/test/windows_processes_test.dart': {
    'CLASS:WindowsProcessTestFileSystem': 'internal',
    'CLASS:WindowsProcessTestPaths': 'internal',
    'FUNCTION:main': 'entrypoint',
    'FUNCTION:startWaitingChild': 'internal',
  },
  'workspace:packages/dart_mobile_device/test/device_prepare_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/dart_mobile_device/test/device_roles_test.dart': {
    'CLASS:DiagnosticsChild': 'internal',
    'CLASS:DiagnosticsHostPolicy': 'internal',
    'CLASS:DiagnosticsProcesses': 'internal',
    'CLASS:ForbiddenPrivileges': 'internal',
    'CLASS:ProbeHttpClient': 'internal',
    'CLASS:ProbeHttpRequest': 'internal',
    'CLASS:ProbeHttpResponse': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/dart_mobile_device/test/device_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/dart_mobile_device/test/gdb_remote_client_test.dart': {
    'FUNCTION:_frame': 'private',
    'FUNCTION:_incomingFrames': 'private',
    'FUNCTION:_stopSignalTests': 'private',
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_packetEnd': 'private',
    'TOP_LEVEL_VARIABLE:_packetStart': 'private',
  },
  'workspace:packages/dart_mobile_device/test/native_device_sockets_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/dart_mobile_device/test/port_forwarder_exit_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/dart_mobile_device/test/port_forwarder_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/dart_mobile_device/test/pymd_device_resolver_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/dart_mobile_device/test/pymd_devices_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/dart_mobile_device/test/pymd_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/dart_mobile_device/test/remote_pairing_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/dart_mobile_device/test/test_device_sockets.dart': {
    'CLASS:TestDeviceSockets': 'internal',
  },
  'workspace:packages/dart_mobile_device/test/test_log_output.dart': {
    'CLASS:TestDeviceConsole': 'internal',
    'CLASS:TestLogOutput': 'internal',
    'FUNCTION:testLocalHttp': 'internal',
    'FUNCTION:testLog': 'internal',
    'FUNCTION:testSink': 'internal',
  },
  'workspace:packages/dart_mobile_device/test/tunnel_discovery_test.dart': {
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_tunneldPort': 'private',
  },
  'workspace:packages/dart_mobile_device/test/tunnel_ownership_test.dart': {
    'CLASS:Child': 'internal',
    'CLASS:Processes': 'internal',
    'CLASS:RelayProbe': 'internal',
    'CLASS:RelaySockets': 'internal',
    'FUNCTION:main': 'entrypoint',
    'FUNCTION:relayTransport': 'internal',
  },
  'workspace:packages/dart_mobile_device/test/tunnel_privilege_error_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/dart_mobile_device/test/tunneld_log_tail_test.dart': {
    'CLASS:MappedTailFileSystem': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/dart_mobile_device/test/wireless_device_preparation_test.dart':
      {
        'CLASS:DeniedPreparationPrivileges': 'internal',
        'CLASS:WirelessChild': 'internal',
        'CLASS:WirelessFixtureFileSystem': 'internal',
        'CLASS:WirelessHostPolicy': 'internal',
        'CLASS:WirelessProcesses': 'internal',
        'FUNCTION:main': 'entrypoint',
      },
  'workspace:packages/darwin_sdk_kit/test/cpio_reader_test.dart': {
    'FUNCTION:chunked': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/darwin_sdk_kit/test/darwin_sdk_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/darwin_sdk_kit/test/darwin_toolchain_test.dart': {
    'CLASS:DarwinToolchainTestIo': 'internal',
    'CLASS:FixtureFileSystem': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/darwin_sdk_kit/test/ios_target_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/darwin_sdk_kit/test/pbzx_reader_test.dart': {
    'FUNCTION:_fixture': 'private',
    'FUNCTION:decodeToBytes': 'internal',
    'FUNCTION:main': 'entrypoint',
    'TOP_LEVEL_VARIABLE:_chunkSize': 'private',
  },
  'workspace:packages/darwin_sdk_kit/test/sdk_log_test_support.dart': {
    'CLASS:SdkTestLogOutput': 'internal',
    'FUNCTION:sdkTestLog': 'internal',
  },
  'workspace:packages/darwin_sdk_kit/test/tbd_bundle_patch_test.dart': {
    'CLASS:TestLinkError': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/darwin_sdk_kit/test/test_fixtures.dart': {
    'CLASS:PbzxChunk': 'fixture',
    'FUNCTION:buildCpioEntry': 'fixture',
    'FUNCTION:buildCpioTrailer': 'fixture',
    'FUNCTION:buildPbzx': 'fixture',
    'FUNCTION:buildXar': 'fixture',
    'FUNCTION:xzCompress': 'fixture',
  },
  'workspace:packages/darwin_sdk_kit/test/xar_reader_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/darwin_sdk_kit/test/xcode_xip_extractor_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/frontend_server_kit/test/compiler_lifecycle_test.dart': {
    'CLASS:Factory': 'internal',
    'CLASS:Transport': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/frontend_server_kit/test/frontend_server_session_test.dart':
      {'FUNCTION:main': 'entrypoint'},
  'workspace:packages/frontend_server_kit/test/mapped_session_test.dart': {
    'CLASS:MappedCompilerFactory': 'internal',
    'CLASS:MappedCompilerTransport': 'internal',
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/frontend_server_kit/test/package_uris_test.dart': {
    'FUNCTION:main': 'entrypoint',
  },
  'workspace:packages/frontend_server_kit/test/support/mapped_frontend_file_system.dart':
      {'CLASS:MappedFrontendFileSystem': 'internal'},
  'workspace:packages/frontend_server_kit/test/test_log_output.dart': {
    'CLASS:TestLogOutput': 'internal',
    'FUNCTION:testLog': 'internal',
    'FUNCTION:testSink': 'internal',
  },
  'package:darwin_sdk_kit/src/shared/tbd/tbd_architecture_rewrite.dart': {
    'CLASS:TbdArchitectureRewrite': 'internal',
    'TOP_LEVEL_VARIABLE:firstLd64LldWithArm64eX1': 'internal',
    'TOP_LEVEL_VARIABLE:unknownArchitectureMarker': 'internal',
    'TOP_LEVEL_VARIABLE:unreadableTapiMarker': 'internal',
  },
  'package:darwin_sdk_kit/src/shared/tbd/tbd_bundle_patch.dart': {
    'ENUM:TbdFileOutcome': 'internal',
  },
  'package:frontend_server_kit/src/host/shared/process/host_compiler_process_factory.dart':
      {'CLASS:HostCompilerTransport': 'internal'},
};
