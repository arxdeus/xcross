import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/host_symlink_capability.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_graph.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_stamp.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';

final class WindowsSwiftPmCheckoutGitPolicy
    implements SwiftPmCheckoutGitPolicy {
  const WindowsSwiftPmCheckoutGitPolicy({required this.symlinks});
  final HostSymlinkCapability symlinks;
  @override
  String linkText(String text) => text.replaceAll('/', r'\');
  @override
  List<String> get checkoutArguments => const ['-c', 'core.longpaths=true'];
  @override
  Future<List<String>> cloneConfiguration() async => [
    ...checkoutArguments,
    if (await symlinks.probe()) ...['-c', 'core.symlinks=true'],
  ];
}

final class WindowsSwiftPmCheckoutFallback<T extends PlatformHostInterface>
    implements SwiftPmCheckoutFallback {
  const WindowsSwiftPmCheckoutFallback({
    required this.runner,
    required this.fileSystem,
    required this.filesystem,
    required this.stamps,
    required this.graph,
  });
  final ProcessRunner<T> runner;
  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmCheckoutStampValidator stamps;
  final SwiftPmCheckoutGraph graph;
  static const _stampKindDirectory = 'directory';
  static const _stampKindHardLink = 'hardlink';
  static const _stampKindForwarder = 'forwarder';
  static String? headerForwarder(String link, String target) {
    const headerExtensions = {'.h', '.hh', '.hpp', '.hxx', '.h++'};
    if (!headerExtensions.contains(p.extension(link).toLowerCase())) {
      return null;
    }
    final relative = p.relative(target, from: p.dirname(link));
    return '#include "${relative.replaceAll(r'\', '/')}"\n';
  }

  @override
  Future<bool> materialize(
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

    final ordered = graph.order(links, resolved);
    for (final link in ordered) {
      final target = resolved[link]!;
      if (fileSystem.directory(target).existsSync()) {
        records.add({
          'path': link,
          'kind': _stampKindDirectory,
          'target': target,
        });
        if (fileSystem.typeSync(link, followLinks: false) !=
            FileSystemEntityType.directory) {
          replace.add(link);
          changed = true;
        }
        directories.add(link);
        continue;
      }
      final forwarder = headerForwarder(link, target);
      if (forwarder != null) {
        records.add({
          'path': link,
          'kind': _stampKindForwarder,
          'target': forwarder,
        });
        if (stamps.linkIntact(link, _stampKindForwarder, forwarder)) {
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
        if (stamps.linkIntact(link, _stampKindHardLink, targets[link]!)) {
          continue;
        }
        replace.add(link);
        hardLinks.add((link, target));
      }
      changed = true;
    }

    if (replace.isNotEmpty || hardLinks.isNotEmpty) {
      await runPlaceholderScript(root, replace: replace, hardLinks: hardLinks);
    }
    for (final (link, forwarder) in forwarders) {
      await fileSystem.file(link).writeAsString(forwarder);
    }
    for (final link in directories) {
      final target = resolved[link]!;
      changed = await filesystem.syncDirectory(target, link) || changed;
    }
    return changed;
  }

  Future<void> runPlaceholderScript(
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
    final scriptFile = fileSystem.file(
      p.join(
        runner.host.paths.temporaryRoot,
        'xcross-placeholders-$pid-${DateTime.now().microsecondsSinceEpoch}.ps1',
      ),
    );
    await scriptFile.writeAsString(script.toString());
    try {
      final result = await runner.run(await runner.locateTool('powershell'), [
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
}
