import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';

String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

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
has_target=false
has_sysroot=false
has_deployment=false
has_fuse_ld=false
has_ld_path=false
expect_target=false
for arg in "\$@"; do
  if \$expect_target; then
    has_target=true
    case "\$arg" in *-apple-*) is_apple_target=true;; esac
    expect_target=false
    continue
  fi
  case "\$arg" in
    -target|--target) expect_target=true;;
    -target=*|--target=*)
      has_target=true
      case "\${arg#*=}" in *-apple-*) is_apple_target=true;; esac;;
    -arch|-arch=*) is_apple_target=true;;
    -miphoneos-version-min=*) is_apple_target=true; has_deployment=true;;
    -mios-simulator-version-min=*) is_apple_target=true; has_deployment=true;;
    -isysroot|--sysroot|-isysroot=*|--sysroot=*) has_sysroot=true;;
    -fuse-ld=*) has_fuse_ld=true;;
    --ld-path=*) has_ld_path=true;;
  esac
done
\$is_apple_target || exec ${[hostCompiler, ...hostCompilerArguments].map(shellQuote).join(' ')} "\$@"
\$has_ld_path || set -- ${shellQuote('--ld-path=$linker')} "\$@"
\$has_fuse_ld || set -- ${shellQuote('-fuse-ld=lld')} "\$@"
\$has_deployment || set -- ${shellQuote(target.minimumVersionFlag(deploymentTarget))} "\$@"
\$has_sysroot || set -- ${shellQuote('-isysroot')} ${shellQuote(iosSdk)} "\$@"
\$has_target || set -- ${shellQuote('--target=${target.buildTriple(deploymentTarget)}')} "\$@"
exec ${shellQuote(clang)} "\$@"
''';

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
String renderUnixXcrunShim(String tool) =>
    '''
#!/bin/sh
case "\$*" in
  --version|-version) echo 'xcrun version 72.'; exit 0;;
esac
exec ${shellQuote(tool)} "\$@"
''';

String renderUnixToolShim(String tool) =>
    '#!/bin/sh\nexec ${shellQuote(tool)} "\$@"\n';

const unixCodesignShim = '#!/bin/sh\nexit 0\n';
