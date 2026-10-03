const architectureSources = {
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
const workspacePackages = {
  'xcross',
  'cli_kit',
  'darwin_sdk_kit',
  'apple_developer_kit',
  'dart_mobile_device',
  'frontend_server_kit',
};
const toolBoundaries = {
  'packages/xcross/tool/build_xcross.dart',
  'packages/xcross/tool/swiftpm_binary_fixture.dart',
  'packages/xcross/tool/swiftpm_gate_evidence.dart',
  'packages/xcross/tool/verify_flutter_notices.dart',
};
const hostFactories = {
  'packages/xcross/lib/src/composition/flutter/windows_flutter_feature_services.dart':
      'windows',
  'packages/xcross/lib/src/composition/host/windows_xcross_context.dart':
      'windows',
  'packages/xcross/lib/src/composition/host/linux_xcross_context.dart': 'linux',
  'packages/xcross/lib/src/composition/host/macos_xcross_context.dart': 'macos',
};

const detectorCallers = {
  'packages/cli_kit/lib/src/composition/native_host.dart': 'detectPlatformHost',
  'packages/xcross/bin/xcross.dart': 'main',
  'packages/xcross/bin/xcrun.dart': 'main',
  'packages/xcross/lib/src/composition/native_runtime.dart':
      'createNativeXcrossContext',
  'packages/xcross/tool/build_xcross.dart': 'main',
};
const detector = 'packages/cli_kit/lib/src/composition/native_host.dart';
const hostComposition =
    'packages/xcross/lib/src/composition/xcross_runtime.dart';
const targetComposition = {
  'packages/xcross/lib/src/composition/ios_target.dart',
};
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
const hostAssemblies = {
  'packages/apple_developer_kit/lib/src/composition/apple_host.dart',
  'packages/apple_developer_kit/lib/src/composition/native_library_loader.dart',
  'packages/xcross/lib/src/composition/host_operations.dart',
};
const compositions = {
  'packages/xcross/lib/src/composition/flutter/posix_flutter_feature_services.dart',

  'packages/apple_developer_kit/lib/src/composition/apple_host.dart',
  'packages/apple_developer_kit/lib/src/composition/native_library_loader.dart',
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
const nativeHooks = {'packages/apple_developer_kit/hook/build.dart'};
const resources = {
  'packages/xcross/lib/src/shared/flutter/build/assets/preview_macro_stub.c':
      Classification('shared', 'shared', 'embedded-native-template'),
  'packages/dart_mobile_device/lib/src/target/iphone/device/pymd/scripts/pair_host.py':
      Classification('shared', 'iphone', 'target-resource'),
};
const templates = {
  'packages/xcross/lib/src/host/shared/flutter/apple_tool_shim_templates_posix.dart',
  'packages/xcross/lib/src/host/windows/flutter/apple_tool_shim_templates.dart',
};

const nativeSources = {
  'packages/apple_developer_kit/src/host/shared/adi/posix_bridge.c': 'shared',
  'packages/apple_developer_kit/src/host/shared/adi/sysv_abi_bridge.c':
      'shared',
};

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

const entrypoints = {
  'packages/xcross/bin/xcross.dart',
  'packages/xcross/bin/xcrun.dart',
};
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
