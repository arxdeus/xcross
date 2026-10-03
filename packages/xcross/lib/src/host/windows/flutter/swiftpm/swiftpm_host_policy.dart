import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/host_symlink_capability.dart';
import 'package:xcross/src/flutter/build/internal/windows_swift_plan_repair.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/checkout_link_creator.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_creator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_order.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

final class WindowsSwiftPmHostPolicy implements SwiftPmHostPolicy {
  WindowsSwiftPmHostPolicy(this.runner, {SwiftPmCheckoutLinkCreator? checkoutLinks, SwiftPmCheckoutAttributes? attributes})
    : checkoutAttributes = attributes ?? WindowsSwiftPmCheckoutAttributes(runner), checkoutLinkCreator = checkoutLinks ?? WindowsSwiftPmCheckoutLinkCreator(), repairs = WindowsSwiftPlanRepair(runner);
  final SwiftPmCheckoutAttributes checkoutAttributes;
  final SwiftPmCheckoutLinkCreator checkoutLinkCreator;
  final ProcessRunner runner;
  final WindowsSwiftPlanRepair repairs;
  @override
  String artifactIdentity(String value)=>value.toLowerCase();
  @override
  Future<void> stageFlutterFramework<T extends PlatformHostInterface>(SwiftPmRuntime<T> runtime, String source, String destination, {bool? copy}) => runtime.filesystem.stageFlutterFramework(source, destination, copy: copy ?? true);
  @override
  List<String> get packagePrefix => const [];
  @override
  List<String> get buildPrefix => const [];
  @override
  String get packageTool => 'swift-package';
  @override
  String get buildTool => 'swift-build';
  @override
  List<String> get manifestArguments => const [
    '-Xmanifest',
    '-Xfrontend',
    '-Xmanifest',
    '-import-module',
    '-Xmanifest',
    '-Xfrontend',
    '-Xmanifest',
    'CRT',
  ];
  @override
  List<String> get buildArguments => [
    ...manifestArguments,
    '--disable-automatic-resolution',
    '-Xswiftc',
    '-no-verify-emitted-module-interface',
    ...SwiftPmBuildPlan.noImplicitModuleLockArguments,
  ];
  @override
  List<String> get linkerArguments => const [];
  @override
  List<String> get fingerprintArguments => const [];
  @override
  List<String> get gitConfiguration => const ['core.symlinks', 'false'];
  @override
  Map<String, String> get sourceEnvironment => const {
    'EXPERIMENTAL_SPM_BUILDS': '1',
  };
  @override
  bool get sourceFallbackActive => true;
  @override
  bool get captureBuildOutput => runner.log.isVerbose;
  @override
  Future<void> resolveDependencies(Future<void> Function() resolve) =>
      resolve();
  @override
  Future<bool> repairBuildPlan(String scratchPath, String targetBuildDir) =>
      repairs.repairWindowsGeneratedBuildFiles(scratchPath, targetBuildDir);
  @override
  Future<void> invokeBuild(
    Future<void> Function() build,
    String scratchPath,
    String targetBuildDir,
  ) async {
    try {
      await build();
    } on Object {
      if (!await repairBuildPlan(scratchPath, targetBuildDir)) rethrow;
      await build();
    }
    await repairBuildPlan(scratchPath, targetBuildDir);
  }

  @override
  Future<void> rewriteDylib(String path, Set<String> names) =>
      MachODylibRewriter.rewriteFile(path, producedDylibNames: names);
  @override
  List<String> orderInteropTargets(String root, List<String> targets) =>
      SwiftPmBuildPlan.orderedWindowsSwiftInteropTargets(root, targets);
  @override
  bool includesInteropTarget(String target, Set<String> candidates) => true;
  @override
  Future<void> recoverEmittedInterop(
    Set<String> emitted,
    Future<void> Function() repair,
    Future<void> Function() build,
    Object error,
    StackTrace stack,
  ) async {
    if (emitted.isEmpty) Error.throwWithStackTrace(error, stack);
    try {
      await repair();
    } on Object {
      Error.throwWithStackTrace(error, stack);
    }
    await build();
  }

  @override
  Future<String?> cCompiler(
    String sysroot,
    DarwinToolchainResolver toolchain,
  ) => toolchain.resolveDarwinClang(sysroot);
  @override
  Future<String?> cxxCompiler(
    String sysroot,
    DarwinToolchainResolver toolchain,
  ) => toolchain.resolveDarwinClang(sysroot, name: 'clang++');
  @override
  Future<void> configureToolset(
    Map<String, Object> toolset,
    String linker,
    String? cc,
    String? cxx,
    Future<String?> Function(String) resolve,
  ) async {
    for (final entry in {
      'cCompiler': ('clang', cc),
      'cxxCompiler': ('clang++', cxx),
    }.entries) {
      final path = entry.value.$2 ?? await resolve(entry.value.$1);
      if (path == null) throw StateError('Could not find ${entry.value.$1}.');
      toolset[entry.key] = {
        'path': path.replaceAll(r'\', '/'),
        'extraCLIOptions': [r'-fdebug-prefix-map=C:\=/'],
      };
    }
    toolset['linker'] = {
      'path': File(linker).resolveSymbolicLinksSync().replaceAll(r'\', '/'),
    };
  }

  @override
  Map<String, String> bundledToolEnvironment(
    PlatformHostInterface host,
    String executable,
    Map<String, String> environment,
  ) {
    final directory = p.dirname(executable);
    if (!File(
      p.join(directory, host.paths.executableName('xcrun')),
    ).existsSync()) {
      return const {};
    }
    final old = host.environment.lookup(environment, 'PATH');
    return {
      'PATH': host.environment.joinPathList([
        directory,
        if (old != null && old.isNotEmpty)
          ...host.environment.splitPathList(old),
      ]),
    };
  }

  @override
  List<String> linkerPathArguments(String path) => ['-Xswiftc', '-Xclang-linker', '-Xswiftc', '--ld-path=$path'];
  @override
  String checkoutLinkText(String text) => text.replaceAll('/', r'\');
  @override
  List<String> get checkoutArguments => const ['-c', 'core.longpaths=true'];
  @override
  void createRelativeLink(String link, String target) => checkoutLinkCreator.create(link, target);

  @override
  Future<void> clearPlaceholderAttributes<T extends PlatformHostInterface>(SwiftPmRuntime<T> runtime, String path) => checkoutAttributes.clear(path);

  @override
  Future<List<String>> cloneConfiguration(
    HostSymlinkCapability symlinks,
  ) async => [
    ...checkoutArguments,
    if (await symlinks.probe()) ...['-c', 'core.symlinks=true'],
  ];
  @override
  Future<void> materializeClone<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String destination,
    String git,
    String vendorDir,
  ) => runtime.checkout
      .materializeGitCheckoutSymlinks(
        destination,
        git: git,
        stampDir: p.join(vendorDir, '.xcross-symlinks'),
      )
      .then((_) {});
  @override
  Future<({Map<String, String> pins, Map<String, String> originals})>
  bootstrapPinnedDependencies<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    Iterable<String> packages,
    String vendorDir,
    Future<void> Function(String, String, String, String)? clone,
  ) => runtime.workspaceStager.bootstrapWindowsPinnedDependencyResolve(
    packages,
    vendorDir,
    clonePackage: clone,
  );
  @override
  Future<void> prepareBinaryArtifacts<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String packageRoot,
    String store,
    String fallback,
    bool capability,
  ) => runtime.binaryRecovery.prepareSupportedBinaryArtifacts(
    packageRoot: packageRoot,
    binaryArtifactStore: store,
    binaryArtifactFallback: fallback,
    packageLocalArtifactJunctionCapability: capability,
  );
  @override
  Future<bool> recoverDependencyArtifacts<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String packageRoot,
    String scratchPath,
    String store,
    String fallback,
    List<SwiftPmPackageDependency> dependencies,
    SwiftPmBinaryAttemptState state,
    bool capability,
  ) async {
    final provenance = await runtime.binaryRecovery.binaryArtifactProvenance(
      packageRoot,
      scratchPath,
      dependencies,
    );
    final normalized = await runtime.interopRepair
        .normalizeResolvedPackageManifests(scratchPath);
    final archive = await runtime.binaryRecovery
        .recoverBootstrapBinaryArtifacts(
          scratchPath: scratchPath,
          binaryArtifactStore: store,
          provenance: provenance,
          attemptState: state,
          swiftPmArtifactJunctionCapability: capability,
        );
    final extraction = await runtime.binaryRecovery
        .stageExtractedBinaryArtifacts(
          scratchPath: scratchPath,
          vendorDir: p.join(scratchPath, '.xcross-vendor'),
          binaryArtifactStore: store,
          binaryArtifactFallback: fallback,
          attemptState: state,
        );
    return normalized || archive || extraction;
  }

  @override
  Future<Map<String, Object>> buildToolchainIdentity<
    T extends PlatformHostInterface
  >(SwiftPmRuntime<T> runtime, DarwinSdk? sdk) {
    if (sdk == null) {
      throw FlutterBuildError(
        'Darwin Swift SDK not found. Run `xcross sdk install <Xcode.xip>` first.',
      );
    }
    return runtime.toolchain.resolveBuildToolchainIdentity(sdk);
  }

  static const _stampKindSymlink = 'symlink';
  static const _stampKindForwarder = 'forwarder';
  static const _stampKindHardLink = 'hardlink';
  static const _stampKindDirectory = 'directory';

  @override
  Future<bool> materializeFallback<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String root,
    Map<String, String> links,
    Map<String, String> targets,
    Map<String, String> resolved,
    List<Map<String, Object?>> records,
  ) async {
    final replace = <String>[];
    final hardLinks = <(String, String)>[];
    final forwarders = <(String, String)>[];
    final directories = <String>[];
    var changed = false;

    // Directories are ordered so a link inside another link's target is
    // materialized before that target is copied.
    final ordered = orderCheckoutLinks(links, resolved);
    for (final link in ordered) {
      final target = resolved[link]!;
      if (Directory(target).existsSync()) {
        records.add({
          'path': link,
          'kind': _stampKindDirectory,
          'target': target,
        });
        if (FileSystemEntity.typeSync(link, followLinks: false) !=
            FileSystemEntityType.directory) {
          replace.add(link);
          changed = true;
        }
        directories.add(link);
        continue;
      }
      final forwarder = SwiftPmCheckout.headerForwarder(link, target);
      if (forwarder != null) {
        records.add({
          'path': link,
          'kind': _stampKindForwarder,
          'target': forwarder,
        });
        if (runtime.checkout.linkIntact(link, _stampKindForwarder, forwarder)) {
          continue;
        }
        replace.add(link);
        forwarders.add((link, forwarder));
      } else {
        records.add({
          'path': link,
          'kind': _stampKindHardLink,
          'target': targets[link],
        });
        if (runtime.checkout.linkIntact(
          link,
          _stampKindHardLink,
          targets[link]!,
        )) {
          continue;
        }
        replace.add(link);
        hardLinks.add((link, target));
      }
      changed = true;
    }

    if (replace.isNotEmpty || hardLinks.isNotEmpty) {
      await runPlaceholderScript(
        runtime,
        root,
        replace: replace,
        hardLinks: hardLinks,
      );
    }
    for (final (link, forwarder) in forwarders) {
      await File(link).writeAsString(forwarder);
    }
    for (final link in directories) {
      final target = resolved[link]!;
      changed = await runtime.filesystem.syncDirectory(target, link) || changed;
    }
    return changed;
  }

  /// One PowerShell process that clears the read-only bit Git for Windows
  /// puts on placeholders, deletes them, and creates the hard links.

  Future<void> runPlaceholderScript<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String root, {
    required List<String> replace,
    required List<(String, String)> hardLinks,
  }) async {
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final script = StringBuffer()
      ..writeln(r"$ErrorActionPreference = 'Stop'")
      ..writeln(r'$readOnly = [IO.FileAttributes]::ReadOnly')
      ..writeln(r'$reparse = [IO.FileAttributes]::ReparsePoint')
      ..writeln(r'foreach ($path in @(')
      ..writeln(replace.map(quote).join(',\n'))
      ..writeln(')) {')
      ..writeln(
        r'  if (-not ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path))) { continue }',
      )
      ..writeln(r'  $attributes = [IO.File]::GetAttributes($path)')
      ..writeln(
        r'  if ($attributes -band $readOnly) { [IO.File]::SetAttributes($path, $attributes -band (-bnot $readOnly)) }',
      )
      ..writeln(r'  if ([IO.Directory]::Exists($path)) {')
      ..writeln(
        r'    if ($attributes -band $reparse) { [IO.Directory]::Delete($path) } else { Remove-Item -LiteralPath $path -Recurse -Force }',
      )
      ..writeln(r'  } else { [IO.File]::Delete($path) }')
      ..writeln('}')
      // Hashtables, not nested arrays: PowerShell flattens `@(@(a, b))`.
      ..writeln(r'foreach ($pair in @(')
      ..writeln(
        hardLinks
            .map(
              (pair) =>
                  '@{ Path = ${quote(pair.$1)}; Target = ${quote(pair.$2)} }',
            )
            .join(',\n'),
      )
      ..writeln(')) {')
      ..writeln(
        r'  New-Item -ItemType HardLink -Path $pair.Path -Value $pair.Target | Out-Null',
      )
      ..writeln('}');
    final scriptFile = File(
      p.join(
        Directory.systemTemp.path,
        'xcross-placeholders-$pid-${DateTime.now().microsecondsSinceEpoch}.ps1',
      ),
    );
    await scriptFile.writeAsString(script.toString());
    try {
      final result = await runtime.runner
          .run(await runtime.runner.locateTool('powershell'), [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            scriptFile.path,
          ]);
      if (result.exitCode != 0) {
        throw FileSystemException(
          'Could not materialize checkout placeholders: ${result.stderr}',
          root,
        );
      }
    } finally {
      if (scriptFile.existsSync()) await scriptFile.delete();
    }
  }

  @override
  WindowsSwiftPmGatePlatform get gatePlatform =>
      const WindowsSwiftPmGatePlatform();
}
