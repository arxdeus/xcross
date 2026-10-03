import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';

final class AppleToolchainStager<T extends PlatformHostInterface> {
  const AppleToolchainStager(
    this.runner, {
    this.runningExecutable,
    this.makeExecutable,
  });
  final ProcessRunner<T> runner;
  final String? runningExecutable;
  final void Function(String)? makeExecutable;
  Future<void> stage(String stagingRoot, ComposeToolchain<T> toolchain) async {
    final appleToolchain = p.join(stagingRoot, 'apple-toolchain');
    final bin = p.join(appleToolchain, 'bin');
    runner.host.fileSystem.directory(bin).createSync(recursive: true);
    // AppleConfigurablesImpl.getAbsoluteTargetToolchain() resolves to
    // "$appleToolchain/usr", and MacOSBasedLinker.compilerRtDir does
    // runner.host.fileSystem.file("$absoluteTargetToolchain/lib/clang/").getListFiles().firstOrNull()
    // + "/lib/darwin/" — it picks whatever single subdirectory happens to
    // exist under lib/clang (there's normally exactly one, the clang version)
    // and expects Xcode's compiler-rt layout underneath. Kotlin's
    // getListFiles() throws NoSuchFileException (rather than returning an
    // empty list) when lib/clang itself doesn't exist at all, so it must
    // exist; MacOSBasedLinker.provideCompilerRtLibrary then builds an exact
    // filename from there — "$compilerRtDir/libclang_rt.<platform><sim
    // suffix>.a" for a static (non-asan/tsan) link, e.g.
    // ".../lib/clang/<version>/lib/darwin/libclang_rt.ios.a" — and the link
    // step fails with "undefined symbol: __isPlatformVersionAtLeast" (a
    // symbol compiler-rt provides) if that file isn't the real one. Stage
    // the real libclang_rt.*.a files from the local Darwin SDK artifact
    // bundle's own Xcode toolchain into a same-shaped versioned directory,
    // for every Family MacOSBasedLinker's provideCompilerRtLibrary switches
    // on (ios, watchos, tvos, osx — confirmed via its WhenMappings; this
    // compiler has no xrOS/visionOS case, so libclang_rt.xros*.a is never
    // requested and is skipped to keep staging small).
    final clangDir = runner.host.fileSystem.directory(
      p.join(appleToolchain, 'usr', 'lib', 'clang'),
    )..createSync(recursive: true);
    final darwinRt = _findCompilerRtDarwinDir(
      toolchain.darwinSdkBundle,
      runner.host.fileSystem,
    );
    if (darwinRt != null) {
      final stagedDarwin = runner.host.fileSystem.directory(
        p.join(clangDir.path, 'xcross', 'lib', 'darwin'),
      )..createSync(recursive: true);
      for (final name in _compilerRtLibraryNames) {
        final source = runner.host.fileSystem.file(p.join(darwinRt, name));
        if (source.existsSync()) {
          source.copySync(p.join(stagedDarwin.path, name));
        }
      }
    }
    // MacOSBasedLinker's constructor also hardcodes linker/libtool/strip/
    // dsymutil as "$absoluteTargetToolchain/bin/<tool>" (i.e.
    // "$appleToolchain/usr/bin/<tool>"), bypassing any konan.properties
    // override. Stage the same shims there too, or the link step fails
    // with "Cannot run program ".../apple-toolchain/usr/bin/ld"".
    final usrBin = p.join(appleToolchain, 'usr', 'bin');
    runner.host.fileSystem.directory(usrBin).createSync(recursive: true);
    const usrBinTools = {'ld', 'strip', 'dsymutil', 'libtool'};
    for (final entry in _appleToolAliases.entries) {
      final name = runner.host.paths.executableName(entry.key);
      final targets = [bin, if (usrBinTools.contains(entry.key)) usrBin];
      for (final directory in targets) {
        final path = p.join(directory, name);
        await toolchain.host.writeShim(
          path,
          entry.key,
          entry.value,
          runningExecutable ?? toolchain.host.runningExecutable,
          makeExecutable ?? runner.makeExecutable,
        );
      }
    }
  }
}

abstract final class AppleToolEnvironment {
  static Map<String, String> resolve<T extends PlatformHostInterface>(
    ComposeToolchain<T> toolchain,
    String searchPath,
  ) {
    final directory = p.dirname(toolchain.ld64Lld);
    final paths = toolchain.target.host.environment.splitPathList(searchPath);
    String llvmTool(String name, {String? macosFallback}) {
      return toolchain.host.resolveAppleTool(
        directory,
        name,
        paths,
        nativeFallback: macosFallback,
      );
    }

    return {
      'XCROSS_APPLE_TOOL_LD': toolchain.ld64Lld,
      'XCROSS_APPLE_TOOL_STRIP': llvmTool('llvm-strip', macosFallback: 'strip'),
      'XCROSS_APPLE_TOOL_DSYMUTIL': llvmTool('dsymutil'),
      'XCROSS_APPLE_TOOL_LIBTOOL': llvmTool(
        'llvm-libtool-darwin',
        macosFallback: 'libtool',
      ),
      'XCROSS_APPLE_TOOL_CLANG': toolchain.clang,
      'XCROSS_APPLE_TOOL_CLANGXX': p.join(
        p.dirname(toolchain.clang),
        toolchain.target.host.paths.executableName('clang++'),
      ),
    };
  }
}

const _appleToolAliases = {
  'ld': 'XCROSS_APPLE_TOOL_LD',
  'strip': 'XCROSS_APPLE_TOOL_STRIP',
  'dsymutil': 'XCROSS_APPLE_TOOL_DSYMUTIL',
  'libtool': 'XCROSS_APPLE_TOOL_LIBTOOL',
  'clang': 'XCROSS_APPLE_TOOL_CLANG',
  'clang++': 'XCROSS_APPLE_TOOL_CLANGXX',
};

/// The `libclang_rt.*.a` names `MacOSBasedLinker.provideCompilerRtLibrary`
/// can request for a non-sanitizer static link, one per `Family` it
/// switches on: ios/watchos/tvos/osx, each with a `sim` variant for the
/// simulator triples the patched HostManager also reports as enabled.
const _compilerRtLibraryNames = [
  'libclang_rt.ios.a',
  'libclang_rt.iossim.a',
  'libclang_rt.watchos.a',
  'libclang_rt.watchossim.a',
  'libclang_rt.tvos.a',
  'libclang_rt.tvossim.a',
  'libclang_rt.osx.a',
];

/// Finds `.../XcodeDefault.xctoolchain/usr/lib/clang/<version>/lib/darwin`
/// under a Darwin SDK artifact bundle root, the directory Xcode's own clang
/// ships its compiler-rt static libraries in. Returns null when the bundle
/// doesn't have one (e.g. test fixtures, or a stripped-down bundle), in
/// which case the staged `apple-toolchain` simply ends up with an empty
/// compiler-rt directory again, same as before this fix — no compiler-rt
/// library gets linked in, rather than failing to stage at all.
String? _findCompilerRtDarwinDir(
  String darwinSdkBundle,
  HostFileSystemInterface files,
) {
  final clang = files.directory(
    p.join(
      darwinSdkBundle,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'clang',
    ),
  );
  if (!clang.existsSync()) return null;
  // Sorted for determinism: Directory.listSync()'s order is filesystem-
  // dependent, and a real Xcode toolchain only ever ships one clang version
  // subdirectory today (confirmed against a live Darwin SDK bundle), so
  // this is inert in practice, but matches the sorted-listing convention
  // DarwinSdk._firstSdk already uses for the analogous iPhoneOS.sdk pick,
  // for the same reason: an unsorted pick from a directory listing is
  // nondeterministic the moment there's ever more than one candidate.
  final versions = clang.listSync().whereType<Directory>().toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  for (final entry in versions) {
    final darwin = p.join(entry.path, 'lib', 'darwin');
    if (files.directory(darwin).existsSync()) return darwin;
  }
  return null;
}
