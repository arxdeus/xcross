import 'inventory.dart';

Map<String, (String, Set<String>)> dependencyFixtures() => {
  'composition_import': (
    '''import 'package:xcross/src/composition/ios_target.dart' show composeBuildFeatures; Object build()=>composeBuildFeatures('iphone',throw StateError('host'));''',
    {'composition-edge'},
  ),
  'concrete_import': (
    '''import '../host/windows/adapter.dart'; void build() {}''',
    {'concrete-edge'},
  ),
};

Map<String, (String, Set<String>)> dependencyAssets() {
  final result = <String, (String, Set<String>)>{};
  for (final entry in {
    'packages/fixture/lib/src/host/linux/capability.dart':
        "abstract class PlatformHostInterface { String get architecture; } class LinuxComposeHost { final PlatformHostInterface host; LinuxComposeHost(this.host); void validate() { if (host.architecture != 'arm64') throw UnsupportedError('unsupported CPU'); } bool get supported => host.architecture == 'arm64'; }",
    'packages/fixture/lib/src/host/linux/disguised.dart':
        "abstract class PlatformHostInterface { String get architecture; } void build(PlatformHostInterface host) { if(host.architecture == 'arm64') { print('compiler'); throw UnsupportedError('bad'); } }",
    'packages/fixture/lib/src/host/linux/asset_mapping.dart':
        "abstract class PlatformHostInterface { String get architecture; } String asset(PlatformHostInterface host) => switch(host.architecture) { 'arm64' => 'linux-arm64.tar.gz', _ => throw UnsupportedError('unsupported CPU') };",
    'packages/fixture/lib/src/host/windows/asset_mapping.dart':
        "abstract class PlatformHostInterface { String get architecture; } String asset(PlatformHostInterface host) => host.architecture == 'arm64' ? throw UnsupportedError('unsupported CPU') : 'windows-x64.zip';",
    'packages/xcross/lib/src/composition/native_runtime.dart':
        "import 'package:cli_kit/src/composition/native_host.dart'; Object createNativeXcrossContext() => detectPlatformHostSnapshot(); Object disguisedFactory() => detectPlatformHostSnapshot();",
    detector:
        "import 'dart:io'; String detectPlatformHostSnapshot() => Platform.operatingSystem; String another() => Platform.operatingSystem;",
    'packages/apple_developer_kit/hook/build.dart':
        "import 'dart:io'; import 'package:code_assets/code_assets.dart'; String _resolveSystemCc() => Platform.environment['PATH'] ?? ''; Object _buildWithSystemCc() => OS.current; Object another() => OS.current; void main(OS input) { if(input == OS.windows) print('hook'); }",
    'packages/xcross/test/guard_public_fixture.dart': 'class _TestDouble {}',
    '.github/rogue.dat': 'unknown CI asset',
    'packages/fixture/lib/src/legacy/bin/native': 'unknown binary',
    'packages/fixture/lib/filtered.dart':
        "export 'fixture.dart' show Contract;",
    'packages/fixture/lib/filtered_twice.dart': "export 'filtered.dart';",
    'packages/fixture/lib/cycle_a.dart':
        "export 'cycle_b.dart'; export 'src/shared/contract.dart';",
    'packages/fixture/lib/cycle_b.dart': "export 'cycle_a.dart';",
    'packages/fixture/lib/conditional_filtered.dart':
        "export 'filtered_twice.dart' if(dart.library.io) 'filtered.dart';",
    'packages/fixture/lib/conditional_leak.dart':
        "export 'filtered_twice.dart' if(dart.library.html) 'fixture.dart';",
    'packages/fixture/lib/src/shared/multihop.dart':
        "import '../../filtered_twice.dart'; Contract? build()=>null;",
    'packages/fixture/lib/src/shared/cycle_import.dart':
        "import '../../cycle_a.dart'; Contract? build()=>null;",
    'packages/fixture/lib/src/shared/conditional_filtered_import.dart':
        "import '../../conditional_filtered.dart'; Contract? build()=>null;",
    'packages/fixture/lib/src/shared/conditional_leak_import.dart':
        "import '../../conditional_leak.dart'; void build() {}",
    'packages/fixture/lib/src/shared/conditional_show_import.dart':
        "import '../../conditional_leak.dart' show Contract; Contract? build()=>null;",
    'packages/fixture/lib/src/shared/hide_import.dart':
        "import '../../fixture.dart' hide Adapter; Contract? build()=>null;",
    'packages/fixture/lib/src/shared/repeated_combinators.dart':
        "import '../../fixture.dart' show Contract, Adapter hide Adapter; Contract? build()=>null;",
    'packages/cli_kit/lib/src/shared/legacy_import.dart':
        "import '../old.dart'; void build() {}",
    'packages/cli_kit/lib/src/old.dart': 'class Old {}',
    'packages/fixture/lib/src/shared/private_generated.g.dart':
        'class _Generated {}',
    'packages/fixture/lib/src/shared/public_generated.g.dart':
        'class Generated {}',
    hostComposition:
        'abstract class WindowsHostInterface {} int composeXcrossHost(Object host) => switch(host) { WindowsHostInterface() => 1, _ => 2 };',
    'packages/xcross/lib/src/composition/ios_target.dart':
        "int fakeFactory(String renamed) => switch(renamed) { 'simulator' => 1, _ => 2 };",
    'packages/fixture/lib/fixture.dart':
        "export 'src/host/windows/adapter.dart'; export 'src/shared/contract.dart';",
    'packages/fixture/lib/src/shared/contract.dart':
        'abstract class Contract {}',
    'packages/fixture/lib/src/shared/narrow_import.dart':
        "import '../../fixture.dart' show Contract; Contract? build() => null;",
    'packages/fixture/lib/src/shared/concrete_show.dart':
        "import '../../fixture.dart' show Adapter; Adapter? build() => null;",
    'packages/fixture/lib/src/shared/generated.g.dart':
        "import 'dart:io' as runtime; bool build() => runtime.Platform.isLinux;",
    'packages/fixture/lib/src/shared/barrel_import.dart':
        "import '../../fixture.dart'; void build() {}",
    'packages/fixture/lib/src/host/unknown/adapter.dart': 'class Adapter {}',
    'packages/fixture/lib/src/legacy.dart': 'void old() {}',
    'packages/fixture/lib/src/unknown.dat': 'asset',
    'packages/fixture/lib/src/host/windows/adapter.dart': 'class Adapter {}',
  }.entries) {
    final explicit = <String, Set<String>>{
      'packages/fixture/lib/filtered.dart': {},
      'packages/fixture/lib/filtered_twice.dart': {},
      'packages/fixture/lib/cycle_a.dart': {},
      'packages/fixture/lib/cycle_b.dart': {},
      'packages/fixture/lib/conditional_filtered.dart': {},
      'packages/fixture/lib/conditional_leak.dart': {},
      'packages/fixture/lib/src/shared/multihop.dart': {},
      'packages/fixture/lib/src/shared/cycle_import.dart': {},
      'packages/fixture/lib/src/shared/conditional_filtered_import.dart': {},
      'packages/fixture/lib/src/shared/conditional_leak_import.dart': {
        'concrete-edge',
      },
      'packages/fixture/lib/src/shared/conditional_show_import.dart': {},
      'packages/fixture/lib/src/shared/hide_import.dart': {},
      'packages/fixture/lib/src/shared/repeated_combinators.dart': {},
      'packages/cli_kit/lib/src/shared/legacy_import.dart': {'legacy-edge'},
      'packages/cli_kit/lib/src/old.dart': {'inventory'},
      'packages/fixture/lib/src/shared/private_generated.g.dart': {
        'private-type',
      },
      'packages/fixture/lib/src/shared/public_generated.g.dart': {},
    };
    final expected =
        explicit[entry.key] ??
        ((entry.key.endsWith('capability.dart') ||
                entry.key.endsWith('asset_mapping.dart'))
            ? {}
            : entry.key.endsWith('disguised.dart')
            ? {'platform-branch'}
            : entry.key == detector || entry.key.endsWith('hook/build.dart')
            ? {'ambient-detection'}
            : entry.key.endsWith('guard_public_fixture.dart')
            ? {'private-type'}
            : entry.key.endsWith('composition/native_runtime.dart')
            ? {'hidden-detection'}
            : entry.key == hostComposition
            ? {}
            : entry.key.endsWith('composition/ios_target.dart')
            ? {'platform-branch'}
            : entry.key.contains('host/windows') ||
                  entry.key.endsWith('/fixture.dart')
            ? {}
            : entry.key.endsWith('barrel_import.dart') ||
                  entry.key.endsWith('concrete_show.dart')
            ? {'concrete-edge'}
            : entry.key.endsWith('generated.g.dart')
            ? {'ambient-detection', 'identity-bool'}
            : entry.key.endsWith('contract.dart') ||
                  entry.key.endsWith('narrow_import.dart')
            ? {}
            : {'inventory'});
    result[entry.key] = (entry.value, expected);
  }
  return result;
}
