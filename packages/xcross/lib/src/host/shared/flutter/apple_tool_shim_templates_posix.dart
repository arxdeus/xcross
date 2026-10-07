import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:meta/meta.dart';

@internal
String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

@internal
String renderUnixCompilerShim({
  required String iosSdk,
  required String clang,
  required String hostCompiler,
  required String linker,
  required String deploymentTarget,
  required IosBuildPlatformInterface target,
  List<String> hostCompilerArguments = const [],
}) =>
    '''
#!/bin/sh
is_apple_target=false
is_macos_target=false
has_target=false
has_sysroot=false
has_deployment=false
has_fuse_ld=false
has_ld_path=false
expect_target=false
for arg in "\$@"; do
  if \$expect_target; then
    has_target=true
    case "\$arg" in
      *-apple-macos*|*-apple-darwin*) is_macos_target=true;;
      *-apple-*) is_apple_target=true;;
    esac
    expect_target=false
    continue
  fi
  case "\$arg" in
    -target|--target) expect_target=true;;
    -target=*|--target=*)
      has_target=true
      case "\${arg#*=}" in
        *-apple-macos*|*-apple-darwin*) is_macos_target=true;;
        *-apple-*) is_apple_target=true;;
      esac;;
    -arch|-arch=*) is_apple_target=true;;
    -mmacosx-version-min=*|-mmacos-version-min=*) is_macos_target=true;;
    -miphoneos-version-min=*|-mios-version-min=*) is_apple_target=true; has_deployment=true;;
    -mios-simulator-version-min=*) is_apple_target=true; has_deployment=true;;
    -isysroot|--sysroot|-isysroot=*|--sysroot=*) has_sysroot=true;;
    -fuse-ld=*) has_fuse_ld=true;;
    --ld-path=*) has_ld_path=true;;
  esac
done
if \$is_macos_target || ! \$is_apple_target; then
  exec ${[hostCompiler, ...hostCompilerArguments].map(shellQuote).join(' ')} "\$@"
fi
\$has_ld_path || set -- ${shellQuote('--ld-path=$linker')} "\$@"
\$has_fuse_ld || set -- ${shellQuote('-fuse-ld=lld')} "\$@"
\$has_deployment || set -- ${shellQuote(target.minimumVersionFlag(deploymentTarget))} "\$@"
\$has_sysroot || set -- ${shellQuote('-isysroot')} ${shellQuote(iosSdk)} "\$@"
\$has_target || set -- ${shellQuote('--target=${target.buildTriple(deploymentTarget)}')} "\$@"
exec ${shellQuote(clang)} "\$@"
''';

@internal
String renderUnixOtoolShim({required String tool, required bool usesObjdump}) =>
    usesObjdump
    ? '''
#!/bin/sh
case "\${1-}" in
  -L) shift; exec ${shellQuote(tool)} --macho --dylibs-used "\$@";;
  -D) shift; exec ${shellQuote(tool)} --macho --dylib-id "\$@";;
  -l) shift; exec ${shellQuote(tool)} --macho --private-headers "\$@";;
  --version) exec ${shellQuote(tool)} --version;;
  *) echo "otool: unsupported option \${1-}" >&2; exit 64;;
esac
'''
    : renderUnixToolShim(tool);

/// xcrun shim. native_toolchain_c probes `xcrun --version` and requires a
/// zero exit plus a parseable version before it asks for SDK paths, so the
/// shim answers that probe itself regardless of which xcrun it forwards to.
///
/// It also probes the `macosx`, `iphoneos` and `iphonesimulator` SDK paths and
/// warns for each one that fails, although it only compiles against the
/// targeted SDK. Probes for the other SDKs return the empty directories in
/// [placeholderSdks], so the build output stays quiet.
@internal
String renderUnixXcrunShim(
  String tool, {
  String? targetSdk,
  String? placeholderSdks,
}) {
  final untargeted = [
    for (final sdk in xcrunProbedSdks)
      if (sdk != targetSdk) sdk,
  ];
  String probe(String sdk) {
    final placeholder = shellQuote('$placeholderSdks/$sdk.sdk');
    return "  '--sdk $sdk --show-sdk-path'|'--sdk=$sdk --show-sdk-path') "
        'echo $placeholder; exit 0;;\n';
  }

  final probes = targetSdk == null || placeholderSdks == null
      ? ''
      : untargeted.map(probe).join();
  return '#!/bin/sh\n'
      'case "\$*" in\n'
      "  --version|-version) echo 'xcrun version 72.'; exit 0;;\n"
      '${probes}esac\n'
      'exec ${shellQuote(tool)} "\$@"\n';
}

/// SDK names native_toolchain_c probes while resolving an Apple sysroot.
@internal
const xcrunProbedSdks = ['macosx', 'iphoneos', 'iphonesimulator'];

@internal
String renderUnixToolShim(String tool) =>
    '#!/bin/sh\nexec ${shellQuote(tool)} "\$@"\n';

@internal
const unixCodesignShim = '#!/bin/sh\nexit 0\n';
