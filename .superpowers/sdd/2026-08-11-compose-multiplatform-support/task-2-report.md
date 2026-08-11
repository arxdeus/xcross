# Task 2 report: Detect KMP projects and resolve app identity

## Changes
- Added `packages/xcross/lib/src/compose/compose.dart` barrel exports.
- Added `ComposeConfiguration` and `ComposeBuildOptions` with debug defaults and explicit bundle/app/ipa options.
- Added `IosAppConfig.parse` and `IosAppConfig.load` for `iosApp/Configuration/Config.xcconfig`.
- Added `KmpProject.detect` with Gradle module detection, KMP iOS framework candidate detection, Kotlin runnable entry classification, Swift `@main` app classification, framework-only fallback, ambiguity errors, Swift source/import collection, and identity precedence.
- Added focused tests for xcconfig parsing/loading and KMP project detection behavior.

## RED evidence
- `dart test packages/xcross/test/compose/ios_app_config_test.dart`
  - Failed to load because `packages/xcross/lib/src/compose/project/ios_app_config.dart` did not exist and `IosAppConfig` was undefined.
- `dart test packages/xcross/test/compose/kmp_project_test.dart`
  - Failed to load because `packages/xcross/lib/src/compose/project/kmp_project.dart` did not exist and `KmpProject`/`KmpEntryKind` were undefined.

## GREEN evidence
- `dart test packages/xcross/test/compose/ios_app_config_test.dart`
  - Passed after implementing xcconfig parsing and loading.
- Final focused verification:
  - Command: `dart format packages/xcross/lib/src/compose packages/xcross/test/compose && dart test packages/xcross/test/compose/ios_app_config_test.dart packages/xcross/test/compose/kmp_project_test.dart && dart analyze packages/xcross/lib/src/compose packages/xcross/test/compose`
  - Result: formatted 6 files, 14 tests passed, targeted analysis found no issues.

## Validation
- Covered simple assignments, comments, conditional key suffixes, known `$(VAR)` expansion, missing version defaults, missing config returning null, and config file loading.
- Covered flat and nested Gradle includes, `iosArm64` plus `binaries.framework` modules, explicit `baseName`, inferred leaf base names, Kotlin runnable Compose entry detection, Swift `@main` detection excluding Preview Content, framework-only fallback, no iOS module errors, module ambiguity errors, and identity precedence.
- Preserved current branch work by adding only the requested compose implementation and tests.
- Did not restore xtool configuration or unrelated legacy code.

## Commit
- `0a771ee5e993e2ff339ecf969e0688ea4c4fb908` feat(cmp): detect kotlin multiplatform projects

## Concerns
- `IosAppConfig.parse` intentionally has a file-level lint ignore for `prefer_constructors_over_static_methods` because the task explicitly requires a static `parse(String)` API.
- Ambiguity resolution requires exactly one Swift import match when multiple modules qualify. This keeps ambiguity an error as requested.

## Follow-ups
- Integrate `KmpProject.detect` into subsequent Compose build/run tasks.
- Add end-to-end fixtures once the Compose build pipeline is implemented.

## Review round 1 fix

### Changes
- Aggregated Swift import evidence across all non-excluded `iosApp` Swift sources before disambiguating multiple KMP modules.
- Excluded `Preview Content`, `*Tests`, and `*UITests` Swift paths from module disambiguation.
- Added regressions for conflicting imports across Swift files, ignored preview/test-target imports, and true multi-hop recursive `$(VAR)` xcconfig expansion.

### RED evidence
- `dart test packages/xcross/test/compose/ios_app_config_test.dart packages/xcross/test/compose/kmp_project_test.dart`
  - Failed on conflicting imports because detection returned a `KmpProject` instead of throwing an ambiguity `XcrossError`.
  - Failed on preview/test import exclusion because detection selected `other` from excluded Swift files instead of `shared`.
  - Multi-hop xcconfig regression passed with the existing recursive parser, so no parser change was required.

### GREEN evidence
- `dart format packages/xcross/lib/src/compose packages/xcross/test/compose && dart test packages/xcross/test/compose/ios_app_config_test.dart packages/xcross/test/compose/kmp_project_test.dart && dart analyze packages/xcross/lib/src/compose packages/xcross/test/compose`
  - Result: formatted 6 files, 17 tests passed, targeted analysis found no issues.
