import 'package:meta/meta.dart';

@internal
const architectureSources = {
  'tool/architecture/internal_roles/apple_developer_kit_roles.dart',
  'tool/architecture/internal_roles/apple_developer_kit_tests_roles.dart',
  'tool/architecture/internal_roles/support_packages_roles.dart',
  'tool/architecture/internal_roles/xcross_flutter_roles.dart',
  'tool/architecture/internal_roles/xcross_compose_roles.dart',
  'tool/architecture/internal_roles/xcross_shared_roles.dart',
  'tool/architecture/internal_roles/xcross_platform_roles.dart',
  'tool/architecture/internal_roles/xcross_flutter_tests_roles.dart',
  'tool/architecture/internal_roles/xcross_compose_tests_roles.dart',
  'tool/architecture/internal_roles/xcross_application_tests_roles.dart',
  'tool/architecture/internal_roles/workspace_tools_roles.dart',
  'tool/architecture/internal_policy.dart',
  'tool/architecture/internal_roles.dart',
  'tool/architecture/source_policy_test.dart',
  'tool/architecture/native_acquisition.dart',
  'tool/architecture/acquisition_fixtures.dart',
  'tool/architecture/native_safety.dart',
  'tool/architecture/check.dart',
  'tool/architecture/boundaries.dart',
  'tool/architecture/platform_fixtures.dart',
  'tool/architecture/declaration_fixtures.dart',
  'tool/architecture/dependency_fixtures.dart',
  'tool/architecture/workspace_inventory.dart',
  'tool/architecture/export_graph.dart',
  'tool/architecture/dispatch_rules.dart',
  'tool/architecture/native_rules.dart',
  'tool/architecture/inventory.dart',
  'tool/architecture/identity.dart',
  'tool/architecture/dependencies.dart',
  'tool/architecture/rules.dart',
  'tool/architecture/declarations.dart',
  'tool/architecture/check_test.dart',
};
@internal
const workspacePackages = {
  'xcross',
  'cli_kit',
  'darwin_sdk_kit',
  'apple_developer_kit',
  'dart_mobile_device',
  'frontend_server_kit',
};
@internal
const toolBoundaries = {
  'packages/xcross/tool/build_xcross.dart',
  'packages/xcross/tool/swiftpm_binary_fixture.dart',
  'packages/xcross/tool/swiftpm_gate_evidence.dart',
  'packages/xcross/tool/verify_flutter_notices.dart',
};
@internal
const hostFactories = {
  'packages/xcross/lib/src/composition/flutter/linux_flutter_feature_services.dart':
      'linux',
  'packages/xcross/lib/src/composition/flutter/macos_flutter_feature_services.dart':
      'macos',
  'packages/xcross/lib/src/composition/flutter/windows_flutter_feature_services.dart':
      'windows',
  'packages/xcross/lib/src/composition/host/windows_xcross_context.dart':
      'windows',
  'packages/xcross/lib/src/composition/host/linux_xcross_context.dart': 'linux',
  'packages/xcross/lib/src/composition/host/macos_xcross_context.dart': 'macos',
};

@internal
const detectorCallers = {
  'packages/cli_kit/lib/composition/native_host.dart': 'detectPlatformHost',
  'packages/xcross/bin/xcross.dart': 'main',
  'packages/xcross/bin/xcrun.dart': 'main',
  'packages/xcross/lib/src/composition/native_runtime.dart':
      'createNativeXcrossContext',
  'packages/xcross/tool/build_xcross.dart': 'main',
};
@internal
const detector = 'packages/cli_kit/lib/composition/native_host.dart';
@internal
const hostComposition =
    'packages/xcross/lib/src/composition/xcross_runtime.dart';
@internal
const targetComposition = {
  'packages/xcross/lib/src/composition/ios_target.dart',
};
@internal
const cliCompositions = {
  'packages/xcross/lib/src/composition/cli/runner.dart',
  'packages/xcross/lib/src/composition/cli/flutter_command.dart',
  'packages/xcross/lib/src/composition/cli/compose_command.dart',
  'packages/xcross/lib/src/composition/cli/flutter_build_command.dart',
  'packages/xcross/lib/src/composition/cli/compose_build_command.dart',
  'packages/xcross/lib/src/composition/cli/flutter_run_command.dart',
  'packages/xcross/lib/src/composition/cli/compose_run_command.dart',
  'packages/xcross/lib/src/composition/cli/compose_setup_command.dart',
  'packages/xcross/lib/src/composition/cli/doctor_project_checks.dart',
};
@internal
const hostAssemblies = {
  'packages/apple_developer_kit/lib/composition/apple_host.dart': {
    'packages/apple_developer_kit/lib/src/host/linux/linux_machine_identity.dart',
    'packages/apple_developer_kit/lib/src/host/macos/macos_machine_identity.dart',
    'packages/apple_developer_kit/lib/src/host/windows/windows_machine_identity.dart',
    'packages/apple_developer_kit/lib/src/host/windows/windows_file_permissions.dart',
  },
  'packages/apple_developer_kit/lib/composition/native_library_loader.dart': {
    'packages/apple_developer_kit/lib/src/host/linux/adi/linux_native_library_loader.dart',
    'packages/apple_developer_kit/lib/src/host/macos/adi/macos_native_library_loader.dart',
    'packages/apple_developer_kit/lib/src/host/windows/adi/loader/loader_windows.dart',
  },
  'packages/xcross/lib/src/composition/host_operations.dart': {
    'packages/xcross/lib/src/host/linux/setup/linux_setup_requirements.dart',
    'packages/xcross/lib/src/host/linux/update/linux_update_policy.dart',
    'packages/xcross/lib/src/host/macos/setup/macos_setup_requirements.dart',
    'packages/xcross/lib/src/host/macos/update/macos_update_policy.dart',
    'packages/xcross/lib/src/host/windows/setup/windows_setup_requirements.dart',
    'packages/xcross/lib/src/host/windows/setup/windows_setup_script.dart',
    'packages/xcross/lib/src/host/windows/update/windows_update_policy.dart',
    'packages/xcross/lib/src/host/windows/xcrun/windows_executable.dart',
  },
};
@internal
const standaloneAssemblies = {
  'packages/xcross/tool/swiftpm_binary_fixture.dart': {
    'packages/xcross/lib/src/composition/native_runtime.dart',
  },
  'packages/xcross/tool/swiftpm_gate_evidence.dart': {
    'packages/xcross/lib/src/composition/xcross_runtime.dart',
    'packages/xcross/lib/src/composition/native_runtime.dart',
  },
};
@internal
const targetAssemblies = {
  'packages/xcross/lib/src/composition/cli/compose_command.dart': {
    'packages/dart_mobile_device/lib/target/iphone/device/pymd/pymd.dart',
  },
  'packages/xcross/lib/src/composition/cli/flutter_command.dart': {
    'packages/dart_mobile_device/lib/target/iphone/device/pymd/pymd.dart',
    'packages/dart_mobile_device/lib/target/iphone/tunnel/pymd_tunnel_availability.dart',
  },
  'packages/xcross/lib/src/composition/xcross_application.dart': {
    'packages/dart_mobile_device/lib/target/iphone/device/pymd/pymd.dart',
  },
  'packages/xcross/lib/src/composition/cli/compose_run_command.dart': {
    'packages/dart_mobile_device/lib/target/iphone/device/pymd/pymd.dart',
    'packages/xcross/lib/src/target/iphone/device/core_device_launch_profile.dart',
    'packages/xcross/lib/src/target/iphone/device/device_run_operation.dart',
  },
  'packages/xcross/lib/src/composition/cli/flutter_run_command.dart': {
    'packages/dart_mobile_device/lib/target/iphone/device/pymd/pymd.dart',
    'packages/xcross/lib/src/target/iphone/device/core_device_launch_profile.dart',
    'packages/xcross/lib/src/target/iphone/device/device_run_operation.dart',
  },
  'packages/xcross/lib/src/composition/cli/runner.dart': {
    'packages/dart_mobile_device/lib/target/iphone/diagnostics/pymd_device_diagnostics.dart',
    'packages/xcross/lib/src/target/iphone/cli/basic/tunnel_command.dart',
    'packages/dart_mobile_device/lib/target/iphone/device/device_prepare.dart',
  },
  'packages/xcross/lib/src/composition/host_operations.dart': {
    'packages/dart_mobile_device/lib/target/iphone/device/pymd/pymd.dart',
  },
  'packages/xcross/lib/src/composition/xcrun_sdk.dart': {
    'packages/darwin_sdk_kit/lib/target/iphone/iphone_build_platform.dart',
    'packages/darwin_sdk_kit/lib/target/simulator/simulator_build_platform.dart',
  },
};
@internal
const generatedCompositionParts = {
  'packages/xcross/lib/src/composition/cli/compose_build_command.g.dart':
      'packages/xcross/lib/src/composition/cli/compose_build_command.dart',
  'packages/xcross/lib/src/composition/cli/compose_run_command.g.dart':
      'packages/xcross/lib/src/composition/cli/compose_run_command.dart',
  'packages/xcross/lib/src/composition/cli/compose_setup_command.g.dart':
      'packages/xcross/lib/src/composition/cli/compose_setup_command.dart',
  'packages/xcross/lib/src/composition/cli/flutter_build_command.g.dart':
      'packages/xcross/lib/src/composition/cli/flutter_build_command.dart',
  'packages/xcross/lib/src/composition/cli/flutter_run_command.g.dart':
      'packages/xcross/lib/src/composition/cli/flutter_run_command.dart',
};
@internal
const compositions = {
  'packages/xcross/lib/src/composition/xcross_application.dart',
  'packages/xcross/lib/src/composition/flutter/swiftpm_foundation.dart',
  'packages/xcross/lib/src/composition/flutter/posix_flutter_feature_services.dart',

  'packages/apple_developer_kit/lib/composition/apple_host.dart',
  'packages/apple_developer_kit/lib/composition/native_library_loader.dart',
  'packages/xcross/lib/src/composition/host_operations.dart',
  'packages/xcross/lib/src/composition/xcrun_sdk.dart',
  'packages/xcross/lib/src/composition/xcross_host_context.dart',
  'packages/xcross/lib/src/composition/flutter/swiftpm_checkout.dart',
  ...cliCompositions,
  'packages/xcross/lib/src/composition/native_runtime.dart',
  detector,
  hostComposition,
  ...targetComposition,
};
@internal
const nativeHooks = {'packages/apple_developer_kit/hook/build.dart'};
@internal
const resources = {
  'packages/xcross/lib/src/shared/flutter/build/assets/preview_macro_stub.c':
      Classification('shared', 'shared', 'embedded-native-template'),
  'packages/dart_mobile_device/lib/src/target/iphone/device/pymd/scripts/pair_host.py':
      Classification('shared', 'iphone', 'target-resource'),
};
@internal
const templates = {
  'packages/xcross/lib/src/host/shared/flutter/apple_tool_shim_templates_posix.dart',
  'packages/xcross/lib/src/host/windows/flutter/apple_tool_shim_templates.dart',
};

@internal
const nativeSources = {
  'packages/apple_developer_kit/src/host/shared/adi/posix_bridge.c': 'shared',
  'packages/apple_developer_kit/src/host/shared/adi/sysv_abi_bridge.c':
      'shared',
  'packages/apple_developer_kit/src/host/windows/adi/windows_arm64_abi_bridge.h':
      'windows',
};

@internal
class Classification {
  final String host;
  final String target;
  final String kind;
  const Classification(this.host, this.target, this.kind);
  Map<String, String> toJson() => {
    'host': host,
    'target': target,
    'kind': kind,
  };
}

@internal
class Violation {
  final String path;
  final String rule;
  final int offset;
  final String detail;
  const Violation(this.path, this.rule, this.offset, this.detail);
  Map<String, Object> toJson() => {
    'path': path,
    'rule': rule,
    'offset': offset,
    'detail': detail,
  };
}

@internal
const entrypoints = {
  'packages/xcross/bin/xcross.dart',
  'packages/xcross/bin/xcrun.dart',
};
@internal
const ciFiles = {
  '.github/FUNDING.yml': Classification('shared', 'shared', 'ci-metadata'),
  '.github/ISSUE_TEMPLATE/bug_report.md': Classification(
    'shared',
    'shared',
    'ci-metadata',
  ),
  '.github/ISSUE_TEMPLATE/feature_request.md': Classification(
    'shared',
    'shared',
    'ci-metadata',
  ),
  '.github/dependabot.yml': Classification('shared', 'shared', 'ci-metadata'),
  '.github/actions/setup-darwin-sdk/action.yml': Classification(
    'shared',
    'shared',
    'ci',
  ),
  '.github/scripts/test_architecture_workflow.py': Classification(
    'shared',
    'shared',
    'ci',
  ),
  '.github/scripts/test_darwin_sdk_security.py': Classification(
    'shared',
    'shared',
    'ci',
  ),
  '.github/workflows/architecture.yml': Classification(
    'shared',
    'shared',
    'ci',
  ),
  '.github/workflows/compose-integration.yml': Classification(
    'shared',
    'shared',
    'ci',
  ),
  '.github/workflows/integration.yml': Classification('shared', 'shared', 'ci'),
  '.github/workflows/publish.yml': Classification('shared', 'shared', 'ci'),
  '.github/workflows/release.yml': Classification('shared', 'shared', 'ci'),
  '.github/workflows/warm-darwin-sdk.yml': Classification(
    'shared',
    'shared',
    'ci',
  ),
  '.github/actions/configure-xcode/action.yml': Classification(
    'macos',
    'shared',
    'ci',
  ),
  '.github/scripts/configure_xcode.py': Classification('macos', 'shared', 'ci'),
  '.github/scripts/prepare_simulator_fixture.py': Classification(
    'shared',
    'simulator',
    'ci',
  ),
  '.github/scripts/test_simulator_smoke.py': Classification(
    'shared',
    'simulator',
    'ci',
  ),
  '.github/scripts/simulator_smoke.py': Classification(
    'macos',
    'simulator',
    'ci',
  ),
};

@internal
const partOwners = {
  'packages/xcross/lib/src/composition/cli/compose_build_command.g.dart':
      'packages/xcross/lib/src/composition/cli/compose_build_command.dart',
  'packages/xcross/lib/src/composition/cli/compose_run_command.g.dart':
      'packages/xcross/lib/src/composition/cli/compose_run_command.dart',
  'packages/xcross/lib/src/composition/cli/compose_setup_command.g.dart':
      'packages/xcross/lib/src/composition/cli/compose_setup_command.dart',
  'packages/xcross/lib/src/composition/cli/flutter_build_command.g.dart':
      'packages/xcross/lib/src/composition/cli/flutter_build_command.dart',
  'packages/xcross/lib/src/composition/cli/flutter_run_command.g.dart':
      'packages/xcross/lib/src/composition/cli/flutter_run_command.dart',
  'packages/xcross/lib/src/shared/cli/basic/auth_command.g.dart':
      'packages/xcross/lib/src/shared/cli/basic/auth_command.dart',
  'packages/xcross/lib/src/shared/cli/basic/update_command.g.dart':
      'packages/xcross/lib/src/shared/cli/basic/update_command.dart',
  'packages/xcross/lib/src/shared/cli/internal/xcross_runner.g.dart':
      'packages/xcross/lib/src/shared/cli/internal/xcross_runner.dart',
  'packages/xcross/lib/src/shared/flutter/build/preview_macro_stub_source.g.dart':
      'packages/xcross/lib/src/shared/flutter/build/preview_macro_stub_source.dart',
  'packages/xcross/lib/src/shared/runtime/version.g.dart':
      'packages/xcross/lib/src/shared/runtime/version.dart',
};
