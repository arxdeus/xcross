# Task 1 report: Share the device run lifecycle

## Implementation summary

- Added shared `PackResult` and `PackOutputKind` in `packages/xcross/lib/src/models/pack_result.dart`.
- Added `CoreDeviceLaunchProfile` with native and Flutter profiles, including Flutter VM service, DAP start-paused, checked-mode, and app argument construction.
- Added `DeviceRunOperation.run` to share device discovery, iOS version gating, terminate, install, and launch.
- Updated `CoreDeviceLauncher.launch` to consume `CoreDeviceLaunchProfile` and preserve existing hot reload/DAP session behavior.
- Migrated `FlutterRunCommand` to build a Flutter launch profile and call the shared run operation.
- Moved Flutter pack results to the shared model while preserving `appPath` access for app outputs.

## RED test evidence

- `dart test packages/xcross/test/device/core_device_launch_profile_test.dart`
  - Failed as expected because `packages/xcross/lib/src/device/core_device_launch_profile.dart` did not exist and `CoreDeviceLaunchProfile` was undefined.
- `dart test packages/xcross/test/device/device_run_operation_test.dart`
  - Failed as expected because `packages/xcross/lib/src/device/device_run_operation.dart` did not exist and `DeviceRunOperation` was undefined.

## GREEN test evidence

- `dart test packages/xcross/test/device/core_device_launch_profile_test.dart`
  - Passed: 2 tests.
- `dart test packages/xcross/test/device/device_run_operation_test.dart`
  - Passed: 3 tests.
- Final verification:
  - Command: `dart format packages/xcross/lib/src/device/device_run_operation.dart packages/xcross/lib/src/cli/flutter/subcommands/flutter_run_command.dart && dart test packages/xcross/test/device/core_device_launch_profile_test.dart packages/xcross/test/device/device_run_operation_test.dart packages/xcross/test/cli/flutter_command_args_test.dart && dart analyze packages/xcross/lib/src/device/core_device_launch_profile.dart packages/xcross/lib/src/device/device_run_operation.dart packages/xcross/lib/src/device/core_device_launcher.dart packages/xcross/lib/src/cli/flutter/subcommands/flutter_run_command.dart packages/xcross/lib/src/flutter/build/flutter_pack_operation.dart packages/xcross/test/device/core_device_launch_profile_test.dart packages/xcross/test/device/device_run_operation_test.dart`
  - Result: 27 tests passed and `dart analyze` reported `No issues found!`.

## Files changed

- Created `packages/xcross/lib/src/models/pack_result.dart`
- Created `packages/xcross/lib/src/device/core_device_launch_profile.dart`
- Created `packages/xcross/lib/src/device/device_run_operation.dart`
- Modified `packages/xcross/lib/src/flutter/build/flutter_pack_operation.dart`
- Modified `packages/xcross/lib/src/flutter/flutter.dart`
- Modified `packages/xcross/lib/src/device/core_device_launcher.dart`
- Modified `packages/xcross/lib/src/cli/flutter/subcommands/flutter_run_command.dart`
- Created `packages/xcross/test/device/core_device_launch_profile_test.dart`
- Created `packages/xcross/test/device/device_run_operation_test.dart`

## Self-review

- TDD followed for the new launch profile and device run operation behavior. Both new test files were observed failing for the expected missing-symbol reasons before implementation.
- The shared operation rejects framework-only outputs before device discovery, rejects iOS 16 before terminate/install, and preserves the terminate -> install -> launch order.
- Flutter launch arguments still include VM service flags, DAP `--start-paused`, checked-mode flags, and app arguments.
- `CoreDeviceLauncher` still owns the existing session, debugger, VM service publishing, and hot reload lifecycle.

## Concerns

- `DeviceRunOperation` now emits the device log for all shared runs, which preserves Flutter run visibility and may also be useful for later Compose commands.
- `FlutterRunCommand` logs the app mode before device resolution because hot reload config is built before the shared lifecycle call.

## Fix round 1 evidence

- Reviewer issue: `CoreDeviceLauncher` still had stale `_buildAppArgs` helper docs/signature referring to hot reload after launch argument construction moved to `CoreDeviceLaunchProfile`.
- Fix: inlined the already-built launch arguments into `_launchSuspended` and removed `_buildAppArgs`.
- Verification command: `dart format packages/xcross/lib/src/device/core_device_launcher.dart && dart test packages/xcross/test/device/core_device_launch_profile_test.dart packages/xcross/test/device/device_run_operation_test.dart packages/xcross/test/cli/flutter_command_args_test.dart && dart analyze packages/xcross/lib/src/device/core_device_launcher.dart packages/xcross/lib/src/device/core_device_launch_profile.dart packages/xcross/lib/src/device/device_run_operation.dart packages/xcross/test/device/core_device_launch_profile_test.dart packages/xcross/test/device/device_run_operation_test.dart`
- Result: 27 tests passed and targeted `dart analyze` reported `No issues found!`.
