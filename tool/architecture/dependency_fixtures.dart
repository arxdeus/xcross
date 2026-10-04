import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:meta/meta.dart';

import 'boundaries.dart';

@internal
Map<String, (String, Set<String>)> dependencyFixtures() => {
  'composition_import': (
    '''import 'package:xcross/src/composition/ios_target.dart'; Object build()=>composeBuildFeatures('iphone',throw StateError('host'));''',
    {'composition-edge', 'cross-package-src', 'internal-use'},
  ),
  'concrete_import': (
    '''import '../host/windows/adapter.dart'; void build() {}''',
    {'concrete-edge'},
  ),
};

@internal
Map<String, (String, Set<String>)> dependencyAssets() {
  final result = <String, (String, Set<String>)>{};
  for (final entry in {
    'packages/fixture/lib/src/target/iphone/native_fixture.dart':
        "import 'dart:io' as renamed; Object acquire(String path)=>renamed.File(path);",
    'packages/fixture/lib/src/target/simulator/native_fixture.g.dart':
        "import 'dart:io' as renamed; Object acquire(String path)=>renamed.Directory(path);",
    'packages/cli_kit/lib/src/host/shared/native_file_system.dart':
        "import 'dart:io'; class NativeFileSystem { File file(String path)=>File(path); Directory directory(String path)=>Directory(path); Link link(String path)=>Link(path); }",

    'packages/xcross/lib/src/composition/cli/flutter_run_command.dart':
        "import '../../target/iphone/device/core_device_launch_profile.dart'; import '../../../../../darwin_sdk_kit/lib/target/simulator/simulator_build_platform.dart'; CoreDeviceLaunchProfile wire()=>CoreDeviceLaunchProfile();",
    'packages/xcross/lib/src/target/iphone/device/core_device_launch_profile.dart':
        'class CoreDeviceLaunchProfile {}',
    'packages/darwin_sdk_kit/lib/target/simulator/simulator_build_platform.dart':
        'class SimulatorBuildPlatform {}',

    'packages/xcross/lib/src/composition/cli/flutter_build_command.dart':
        "part 'flutter_build_command.g.dart'; class BuildArgs {}",
    'packages/xcross/lib/src/composition/cli/flutter_build_command.g.dart':
        "part of 'flutter_build_command.dart'; class _PrivateParser {}",
    'packages/xcross/lib/src/composition/cli/rogue.g.dart':
        'class ExtraParser {}',
    'packages/fixture/lib/src/shared/host/device_policy.dart':
        'class DevicePolicy {}',

    'packages/xcross/tool/verify_flutter_notices.dart':
        "import 'dart:io'; void main() { stdout.writeln('verified'); stderr.writeln('unapproved'); } void other() { stdout.writeln('hidden'); }",
    'packages/xcross/tool/swiftpm_binary_fixture.dart':
        "import 'dart:io'; void main() { stdout.writeln('archive'); stderr.writeln('usage'); } void other() { stderr.writeln('hidden'); }",

    'packages/apple_developer_kit/lib/composition/native_library_loader.dart':
        "import '../src/host/linux/adi/linux_native_library_loader.dart'; import 'package:xcross/src/host/windows/setup/windows_setup_requirements.dart'; LinuxNativeLibraryLoader createLinuxNativeLibraryLoader()=>LinuxNativeLibraryLoader();",
    'packages/apple_developer_kit/lib/composition/apple_host.dart':
        "import '../src/host/linux/linux_machine_identity.dart'; LinuxMachineIdentity createLinuxAppleHostServices()=>LinuxMachineIdentity();",
    'packages/apple_developer_kit/lib/src/host/linux/linux_machine_identity.dart':
        'class LinuxMachineIdentity {}',
    'packages/xcross/lib/src/composition/host_operations.dart':
        "import '../host/windows/setup/windows_setup_requirements.dart'; WindowsSetup windowsHostOperations()=>WindowsSetup();",
    'packages/xcross/lib/src/host/windows/setup/windows_setup_requirements.dart':
        'class WindowsSetup {}',
    'packages/xcross/lib/src/composition/unapproved_assembly.dart':
        "import '../host/windows/setup/windows_setup_requirements.dart'; WindowsSetup arbitrary()=>WindowsSetup();",
    'packages/apple_developer_kit/lib/src/shared/unapproved_assembly.dart':
        "import '../host/linux/linux_machine_identity.dart'; LinuxMachineIdentity arbitrary()=>LinuxMachineIdentity();",

    'packages/fixture/lib/src/host/windows/release_metadata.dart':
        r"abstract class PlatformHostInterface { String get architecture; } String asset(PlatformHostInterface host) { if(host.architecture == 'x64') return 'xcross-windows-x64.zip'; throw UnsupportedError('unsupported'); } String adjacent(PlatformHostInterface host) { if(host.architecture == 'x64') return 'xcross-' 'windows-x64.zip'; throw UnsupportedError('unsupported'); } String backend(PlatformHostInterface host) { if(host.architecture == 'x64') return buildWindows(); throw UnsupportedError('bad'); } String interpolated(PlatformHostInterface host) { if(host.architecture == 'x64') return '${buildWindows()}'; throw UnsupportedError('bad'); } String switchEffect(PlatformHostInterface host) => switch(host.architecture) { 'x64' => '${buildWindows()}', _ => 'constant' }; String conditionalEffect(PlatformHostInterface host) => host.architecture == 'x64' ? '${buildWindows()}' : 'constant'; String buildWindows()=>'effect';",

    'packages/apple_developer_kit/lib/src/shared/adi/adi_architecture.dart':
        "import 'dart:ffi'; enum AdiArchitecture { x64; int get elfMachine=>62; static AdiArchitecture forAbi(Abi value)=>x64; }",

    'packages/apple_developer_kit/lib/src/host/linux/adi/linux_native_library_loader.dart':
        r"import 'dart:ffi'; import '../../../shared/adi/adi_architecture.dart'; class LinuxMemoryAllocator {} class OtherAllocator {} class LinuxNativeLibraryLoader { final int machine; LinuxNativeLibraryLoader():machine=AdiArchitecture.forAbi(Abi.current()).elfMachine; static LinuxMemoryAllocator _createAllocator() => switch(Abi.current()) { Abi.linuxX64 || Abi.linuxArm64 => LinuxMemoryAllocator(), final abi => throw UnsupportedError('unsupported $abi') }; Object other() => switch(Abi.current()) { Abi.windowsX64 => OtherAllocator(), _ => throw UnsupportedError('bad') }; }",
    'packages/apple_developer_kit/lib/src/host/macos/adi/macos_native_library_loader.dart':
        r"import 'dart:ffi'; import '../../../shared/adi/adi_architecture.dart'; class MacOSMemoryAllocator {} class MacOSNativeLibraryLoader { final int machine; MacOSNativeLibraryLoader():machine=AdiArchitecture.forAbi(Abi.current()).elfMachine; static MacOSMemoryAllocator _createAllocator() => switch(Abi.current()) { Abi.macosX64 || Abi.macosArm64 => MacOSMemoryAllocator(), final abi => throw UnsupportedError('unsupported $abi') }; Object other() => Abi.current(); }",
    'packages/apple_developer_kit/lib/src/host/windows/adi/loader/loader_windows.dart':
        r"import 'dart:ffi'; class WindowsMemoryAllocator {} class WindowsNativeLibraryLoader { static WindowsMemoryAllocator _createAllocator() { if(Abi.current() != Abi.windowsX64) { throw UnsupportedError('bad ${Abi.current()}'); } return WindowsMemoryAllocator(); } Object other() => Abi.current(); }",
    'packages/xcross/lib/src/host/macos/compose/macos_compose_host.dart':
        "import 'package:xcross/src/host/shared/compose/posix_compose_host.dart'; abstract class PlatformHostInterface { String get architecture; } abstract class MacOSHostInterface implements PlatformHostInterface {} class MacOSComposeHost { final MacOSHostInterface host; MacOSComposeHost(this.host); bool supportsJavaArchitecture(String architecture) => isArm64Architecture(host.architecture) ? isArm64Architecture(architecture) : isX64Architecture(architecture); bool other(String architecture) => isArm64Architecture(host.architecture) ? isArm64Architecture(architecture) : isX64Architecture(architecture); }",
    'packages/xcross/lib/src/composition/xcrun_sdk.dart':
        "abstract class PlatformHostInterface {} abstract class PlatformTargetInterface<T extends PlatformHostInterface> { String get sdkName; } abstract class IosBuildPlatformInterface {} class IPhoneBuildPlatform implements IosBuildPlatformInterface { const IPhoneBuildPlatform(); } class SimulatorBuildPlatform implements IosBuildPlatformInterface { const SimulatorBuildPlatform(); } Object parseXcrunSdkName(PlatformTargetInterface target) { for(final descriptor in const <IosBuildPlatformInterface>[IPhoneBuildPlatform(),SimulatorBuildPlatform()]) { descriptor.toString(); } if(target.sdkName == 'iphonesimulator') return target; throw FormatException('bad'); } Object other(PlatformTargetInterface target) { if(target.sdkName == 'iphonesimulator') return target; throw FormatException('bad'); }",

    'packages/fixture/lib/src/host/linux/capability.dart':
        "abstract class PlatformHostInterface { String get architecture; } class LinuxComposeHost { final PlatformHostInterface host; LinuxComposeHost(this.host); void validate() { if (host.architecture != 'arm64') throw UnsupportedError('unsupported CPU'); } bool get supported => host.architecture == 'arm64'; }",
    'packages/fixture/lib/src/host/linux/disguised.dart':
        "abstract class PlatformHostInterface { String get architecture; } void build(PlatformHostInterface host) { if(host.architecture == 'arm64') { print('compiler'); throw UnsupportedError('bad'); } }",
    'packages/fixture/lib/src/host/linux/asset_mapping.dart':
        "abstract class PlatformHostInterface { String get architecture; } String asset(PlatformHostInterface host) => switch(host.architecture) { 'arm64' => 'linux-arm64.tar.gz', _ => throw UnsupportedError('unsupported CPU') };",
    'packages/fixture/lib/src/host/windows/asset_mapping.dart':
        "abstract class PlatformHostInterface { String get architecture; } String asset(PlatformHostInterface host) => host.architecture == 'arm64' ? throw UnsupportedError('unsupported CPU') : 'windows-x64.zip';",
    'packages/xcross/lib/src/composition/native_runtime.dart':
        "import 'package:cli_kit/composition/native_host.dart'; Object createNativeXcrossContext() => detectPlatformHostSnapshot(); Object disguisedFactory() => detectPlatformHostSnapshot(); Object nested() { Object createNativeXcrossContext() => detectPlatformHostSnapshot(); return createNativeXcrossContext(); } class Log {} class Service { final Log log=Log(); Service(); Service.other():log=Log(); }",
    detector:
        "import 'dart:io'; String detectPlatformHostSnapshot() => Platform.operatingSystem; String another() => Platform.operatingSystem;",
    'packages/apple_developer_kit/hook/build.dart':
        "import 'dart:io'; import 'package:code_assets/code_assets.dart'; String _resolveSystemCc() => Platform.environment['PATH'] ?? ''; Object _buildWithSystemCc() => OS.current; Object another() => OS.current; abstract class PlatformHostInterface { String get operatingSystem; } void main(OS input, PlatformHostInterface host) { if(input == OS.windows) print('hook'); if(host.operatingSystem == 'windows') print('unrelated'); final label = host.operatingSystem; if(label == OS.windows.toString()) print('alias'); void main(OS inner) { if(inner == OS.windows) print('nested'); } } void _buildWithSystemCcOther(PlatformHostInterface host) { if(host.operatingSystem == 'windows') print('rogue'); }",
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
        "export 'native_runtime.dart'; abstract class WindowsHostInterface {} int composeXcrossHost(Object host) => switch(host) { WindowsHostInterface() => 1, _ => 2 }; int another(Object host) { int composeXcrossHost(Object inner) => switch(inner) { WindowsHostInterface() => 1, _ => 2 }; return composeXcrossHost(host); }",
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
      'packages/fixture/lib/src/target/iphone/native_fixture.dart': {
        'native-acquisition',
      },
      'packages/fixture/lib/src/target/simulator/native_fixture.g.dart': {
        'native-acquisition',
      },
      'packages/cli_kit/lib/src/host/shared/native_file_system.dart': {},

      'packages/xcross/lib/src/composition/cli/flutter_run_command.dart': {
        'concrete-edge',
      },
      'packages/xcross/lib/src/target/iphone/device/core_device_launch_profile.dart':
          {},
      'packages/darwin_sdk_kit/lib/target/simulator/simulator_build_platform.dart':
          {},

      'packages/xcross/lib/src/composition/cli/flutter_build_command.dart': {},
      'packages/xcross/lib/src/composition/cli/flutter_build_command.g.dart': {
        'private-type',
      },
      'packages/xcross/lib/src/composition/cli/rogue.g.dart': {'inventory'},
      'packages/fixture/lib/src/shared/host/device_policy.dart': {},

      'packages/xcross/tool/verify_flutter_notices.dart': {'ambient-detection'},
      'packages/xcross/tool/swiftpm_binary_fixture.dart': {'ambient-detection'},

      'packages/apple_developer_kit/lib/composition/native_library_loader.dart':
          {'concrete-edge'},
      'packages/apple_developer_kit/lib/composition/apple_host.dart': {},
      'packages/apple_developer_kit/lib/src/host/linux/linux_machine_identity.dart':
          {},
      'packages/xcross/lib/src/composition/host_operations.dart': {},
      'packages/xcross/lib/src/host/windows/setup/windows_setup_requirements.dart':
          {},
      'packages/xcross/lib/src/composition/unapproved_assembly.dart': {
        'inventory',
        'concrete-edge',
      },
      'packages/apple_developer_kit/lib/src/shared/unapproved_assembly.dart': {
        'concrete-edge',
      },

      'packages/fixture/lib/src/host/windows/release_metadata.dart': {
        'platform-branch',
      },
      'packages/apple_developer_kit/lib/src/shared/adi/adi_architecture.dart':
          {},
      'packages/apple_developer_kit/lib/src/host/linux/adi/linux_native_library_loader.dart':
          {'ambient-detection', 'platform-branch'},
      'packages/apple_developer_kit/lib/src/host/macos/adi/macos_native_library_loader.dart':
          {'ambient-detection'},
      'packages/apple_developer_kit/lib/src/host/windows/adi/loader/loader_windows.dart':
          {'ambient-detection'},
      'packages/xcross/lib/src/host/macos/compose/macos_compose_host.dart': {
        'platform-branch',
      },
      'packages/xcross/lib/src/composition/xcrun_sdk.dart': {'platform-branch'},

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
            ? (entry.key == detector
                  ? {'ambient-detection'}
                  : {'ambient-detection', 'platform-branch'})
            : entry.key.endsWith('guard_public_fixture.dart')
            ? {'private-type'}
            : entry.key.endsWith('composition/native_runtime.dart')
            ? {'hidden-detection', 'hidden-di-default'}
            : entry.key == hostComposition
            ? {'platform-branch'}
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
    final policyExpected = <String, Set<String>>{
      'packages/apple_developer_kit/lib/composition/native_library_loader.dart':
          {'cross-package-src'},
      'packages/fixture/lib/filtered.dart': {
        'export-directive',
        'show-combinator',
        'inventory',
      },
      'packages/fixture/lib/filtered_twice.dart': {
        'export-directive',
        'inventory',
      },
      'packages/fixture/lib/cycle_a.dart': {'export-directive', 'inventory'},
      'packages/fixture/lib/cycle_b.dart': {'export-directive', 'inventory'},
      'packages/fixture/lib/conditional_filtered.dart': {
        'export-directive',
        'inventory',
      },
      'packages/fixture/lib/conditional_leak.dart': {
        'export-directive',
        'inventory',
        'concrete-edge',
      },
      'packages/fixture/lib/fixture.dart': {
        'export-directive',
        'inventory',
        'concrete-edge',
      },
      'packages/fixture/lib/src/shared/conditional_show_import.dart': {
        'show-combinator',
      },
      'packages/fixture/lib/src/shared/hide_import.dart': {'hide-combinator'},
      'packages/fixture/lib/src/shared/repeated_combinators.dart': {
        'show-combinator',
        'hide-combinator',
      },
      'packages/fixture/lib/src/shared/narrow_import.dart': {'show-combinator'},
      'packages/fixture/lib/src/shared/concrete_show.dart': {'show-combinator'},
      'packages/xcross/lib/src/composition/xcross_runtime.dart': {
        'export-directive',
      },
    };
    result[entry.key] = (
      entry.value,
      {...expected, ...?policyExpected[entry.key]},
    );
  }
  final exactPairs = {
    'packages/xcross/lib/src/composition/cli/compose_command.dart': {
      'packages/dart_mobile_device/lib/target/iphone/device/pymd/pymd.dart',
    },
    'packages/xcross/lib/src/composition/cli/compose_run_command.dart': {
      'packages/dart_mobile_device/lib/target/iphone/device/pymd/pymd.dart',
    },
    'packages/xcross/lib/src/composition/cli/flutter_run_command.dart': {
      'packages/dart_mobile_device/lib/target/iphone/device/pymd/pymd.dart',
    },
    'packages/xcross/lib/src/composition/cli/flutter_command.dart': {
      'packages/dart_mobile_device/lib/target/iphone/device/pymd/pymd.dart',
      'packages/dart_mobile_device/lib/target/iphone/tunnel/pymd_tunnel_availability.dart',
    },
    'packages/xcross/lib/src/composition/cli/runner.dart': {
      'packages/dart_mobile_device/lib/target/iphone/diagnostics/pymd_device_diagnostics.dart',
    },
    'packages/xcross/tool/swiftpm_binary_fixture.dart': {
      'packages/xcross/lib/src/composition/native_runtime.dart',
    },
    'packages/xcross/tool/swiftpm_gate_evidence.dart': {
      'packages/xcross/lib/src/composition/xcross_runtime.dart',
      'packages/xcross/lib/src/composition/native_runtime.dart',
    },
  };
  for (final entry in exactPairs.entries) {
    final old = result[entry.key];
    final approved = entry.value
        .map((path) => "import '${fixturePackageUri(path)}';")
        .join(' ');
    final denied = standaloneAssemblies.containsKey(entry.key)
        ? "import 'package:xcross/src/composition/ios_target.dart';"
        : "import 'package:darwin_sdk_kit/target/simulator/simulator_build_platform.dart';";
    final part = generatedCompositionParts.entries
        .where((p) => p.value == entry.key)
        .firstOrNull;
    final partDirective = part == null
        ? ''
        : "part '${part.key.split('/').last}';";
    if (part != null) {
      result[part.key] = ("part of '${entry.key.split('/').last}';", {});
    }
    var source = old?.$1 ?? '';
    final parsed = parseString(content: source, throwIfDiagnostics: false).unit;
    final offset = parsed.declarations.firstOrNull?.offset ?? source.length;
    source = source.replaceRange(offset, offset, '$partDirective ');
    result[entry.key] = (
      '$approved $denied $source',
      {
        ...?old?.$2,
        if (standaloneAssemblies.containsKey(entry.key))
          'composition-edge'
        else
          'concrete-edge',
      },
    );
  }
  return result;
}

@internal
String fixturePackageUri(String path) {
  final parts = path.split('/');
  return 'package:${parts[1]}/${parts.skip(3).join('/')}';
}
