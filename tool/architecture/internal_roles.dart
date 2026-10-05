import 'package:meta/meta.dart';

import 'internal_roles/apple_developer_kit_roles.dart';
import 'internal_roles/apple_developer_kit_tests_roles.dart';
import 'internal_roles/open_apple_macros_roles.dart';
import 'internal_roles/support_packages_roles.dart';
import 'internal_roles/workspace_tools_roles.dart';
import 'internal_roles/xcross_application_tests_roles.dart';
import 'internal_roles/xcross_compose_roles.dart';
import 'internal_roles/xcross_compose_tests_roles.dart';
import 'internal_roles/xcross_flutter_roles.dart';
import 'internal_roles/xcross_flutter_tests_roles.dart';
import 'internal_roles/xcross_platform_roles.dart';
import 'internal_roles/xcross_shared_roles.dart';

@internal
const reviewedDeclarationRoles = <String, Map<String, String>>{
  ...appleDeveloperKitRoles,
  ...appleDeveloperKitTestsRoles,
  ...openAppleMacrosRoles,
  ...supportPackagesRoles,
  ...xcrossFlutterRoles,
  ...xcrossComposeRoles,
  ...xcrossSharedRoles,
  ...xcrossPlatformRoles,
  ...xcrossFlutterTestsRoles,
  ...xcrossComposeTestsRoles,
  ...xcrossApplicationTestsRoles,
  ...workspaceToolsRoles,
};

@internal
const reviewedInternalLibraries = <String>{
  'package:xcross/src/composition/cli/compose_build_command.dart',
  'package:xcross/src/composition/cli/compose_run_command.dart',
  'package:xcross/src/composition/cli/compose_setup_command.dart',
  'package:xcross/src/composition/cli/flutter_build_command.dart',
  'package:xcross/src/composition/cli/flutter_run_command.dart',
  'package:xcross/src/shared/cli/basic/auth_command.dart',
  'package:xcross/src/shared/cli/basic/update_command.dart',
  'package:xcross/src/shared/cli/internal/xcross_runner.dart',
};
