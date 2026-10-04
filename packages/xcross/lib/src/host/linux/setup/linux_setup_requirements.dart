import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/basic/internal/clang_requirement.dart';
import 'package:xcross/src/cli/basic/internal/linux_package_manager.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';

final class LinuxSetupRequirements implements SetupRequirements {
  LinuxSetupRequirements(this.services);
  final SetupRequirementServices services;
  PlatformHostInterface get host => services.host;
  ProcessRunner get runner => services.runner;
  DarwinToolchainResolver get toolchain => services.toolchain;
  static const _requiredTools = [
    'swift',
    'clang',
    'clang++',
    'llvm-ar',
    'ld64.lld',
  ];

  @override
  Future<void> run() async {
    final manager = await resolvePackageManager();

    await services.privileges.cacheCredentials(
      manualHint: manager.manualHint(),
    );
    await installPackages(manager);
    await ensureLinuxClang(manager);
    await ensureFixedLd64Lld(manager);

    final missing = await services.missingTools(
      _requiredTools
          .where((tool) => tool != 'clang' && tool != 'clang++')
          .toList(),
    );
    if (missing.isNotEmpty) {
      throw XcrossError(
        'Missing Linux requirements on PATH after ${manager.name} install: '
        '${missing.join(', ')}.\n'
        'Install the Swift toolchain manually and ensure its bin directory is '
        'on PATH. The lld package must provide ld64.lld.',
      );
    }

    final pipx = await services.ensurePipx(
      attempts: await pipxInstallAttempts(manager),
      manualHint: manager.manualHint([manager.pipxPackage]),
    );
    await services.ensurePymd();
    await services.pipxEnsurePath(pipx);
    runner.log.logDone('Requirements installed');
  }

  Future<void> ensureLinuxClang(LinuxPackageManager manager) async {
    if (await ClangRequirement(
          runner,
        ).resolve(llvmDirectories: toolchain.llvmToolDirs()) !=
        null) {
      return;
    }
    for (final package in await manager.availableVersionedClang(runner)) {
      if (int.parse(package.substring('clang-'.length)) <
          ClangRequirement.minimum) {
        break;
      }
      try {
        await services.runFirstWorking(
          await manager.installAttempts([package], runner, services.privileges),
          label: '${manager.name} install $package',
        );
        if (await ClangRequirement(
              runner,
            ).resolve(llvmDirectories: toolchain.llvmToolDirs()) !=
            null) {
          return;
        }
      } on Object catch (error) {
        runner.log.logWarn('Could not install $package: $error');
      }
    }
    throw XcrossError(
      'Clang ${ClangRequirement.minimum} or newer (clang and clang++) is '
      'required on Linux, but no usable installation was found after '
      '${manager.name} install. Install clang-20 or newer from a repository '
      'for this distribution and put its bin directory on PATH, then retry.',
    );
  }

  Future<LinuxPackageManager> resolvePackageManager() async {
    final detected = await LinuxPackageManager.detect(runner);
    if (detected.length == 1) {
      final only = detected.single;
      runner.log.logInfo('Package manager', only.name);
      return only;
    }

    final picked = detected.isEmpty
        ? promptForPackageManager(
            LinuxPackageManager.values,
            'No supported package manager found on PATH '
            '(${LinuxPackageManager.values.map((m) => m.executable).join(', ')}'
            ').',
          )
        : promptForPackageManager(
            detected,
            'Multiple package managers found on this host.',
          );

    if (await runner.which(picked.executable) == null) {
      throw XcrossError(
        '${picked.executable} is not on PATH, so xcross cannot drive it.\n'
        '${picked.manualHint()}',
      );
    }
    return picked;
  }

  LinuxPackageManager promptForPackageManager(
    List<LinuxPackageManager> choices,
    String reason,
  ) {
    if (!services.console.hasTerminal) {
      throw XcrossError(
        '$reason\n'
        'Re-run `xcross setup` from a terminal to choose one, or install the '
        'requirements yourself:\n'
        '${choices.map((choice) => '    ${choice.manualHint()}').join('\n')}',
      );
    }

    services.console.output.writeln(reason);
    services.console.output.writeln('Which one should xcross use?');
    for (var i = 0; i < choices.length; i++) {
      services.console.output.writeln(
        '  [${i + 1}] ${choices[i].name} '
        '(${choices[i].executable})',
      );
    }
    while (true) {
      services.console.output.write('Choice (1-${choices.length}): ');
      final raw = services.console.readLine()?.trim();
      if (raw == null) {
        throw XcrossError('No package manager selected (stdin closed).');
      }
      final choice = int.tryParse(raw);
      if (choice != null && choice >= 1 && choice <= choices.length) {
        return choices[choice - 1];
      }
      services.console.output.writeln(
        'Invalid choice "$raw". Enter a number 1-${choices.length}.',
      );
    }
  }

  Future<void> installPackages(LinuxPackageManager manager) async {
    final step = runner.log.beginStep(
      'Installing ${manager.name} requirements',
    );
    try {
      await services.runFirstWorking(
        await manager.installAttempts(
          manager.packages,
          runner,
          services.privileges,
        ),
        label: '${manager.name} install',
        tail: step,
      );
      step.done();
    } on Object {
      step.fail();
      rethrow;
    }
  }

  Future<void> ensureFixedLd64Lld(LinuxPackageManager manager) async {
    final onPath = await runner.which(
      'ld64.lld',
      accept: toolchain.usableLd64Lld,
    );
    final defect = onPath == null
        ? null
        : await toolchain.selectorStubDefect(onPath);
    if (onPath != null && defect == null) return;

    var versioned = versionedLd64Llds();
    final newestInstalled = versioned.keys.fold<int?>(
      null,
      (best, version) => best == null || version > best ? version : best,
    );
    if (newestInstalled == null ||
        newestInstalled <
            DarwinToolchainResolver.firstLd64LldWithCorrectSelectorStubs) {
      final offered = await manager.availableVersionedLld(runner);
      final wanted = offered
          .where(
            (name) =>
                int.parse(name.substring(4)) >=
                DarwinToolchainResolver.firstLd64LldWithCorrectSelectorStubs,
          )
          .firstOrNull;
      if (wanted != null) {
        final step = runner.log.beginStep('Installing $wanted');
        try {
          await services.runFirstWorking(
            await manager.installAttempts(
              [wanted],
              runner,
              services.privileges,
            ),
            label: '${manager.name} install',
            tail: step,
          );
          step.done();
        } on Object {
          step.fail();
          rethrow;
        }
        versioned = versionedLd64Llds();
      }
    }
    if (versioned.isEmpty) {
      if (defect != null) runner.log.logWarn(defect);
      return;
    }

    final newest = versioned.keys.reduce((a, b) => a > b ? a : b);
    final current = onPath == null
        ? null
        : await toolchain.ld64LldVersion(onPath);
    if (current != null && current.$1 >= newest) {
      if (defect != null) runner.log.logWarn(defect);
      return;
    }
    const stable = '/usr/local/bin/ld64.lld';
    final managedLink = host.fileSystem.link(stable);
    final existing = managedLink.existsSync()
        ? FileSystemEntityType.link
        : host.fileSystem.file(stable).existsSync()
        ? FileSystemEntityType.file
        : host.fileSystem.directory(stable).existsSync()
        ? FileSystemEntityType.directory
        : FileSystemEntityType.notFound;
    if (existing != FileSystemEntityType.notFound &&
        (existing != FileSystemEntityType.link ||
            !p.basename(managedLink.targetSync()).startsWith('ld64.lld-'))) {
      runner.log.logWarn(
        '$stable is not managed by xcross; leaving it alone. '
        'Put ${versioned[newest]} ahead of it on PATH to use lld $newest.',
      );
      return;
    }
    await runner.runChecked(await runner.locateTool('sudo'), [
      'ln',
      '-sf',
      versioned[newest]!,
      stable,
    ], label: 'link ld64.lld');
    runner.log.logInfo('ld64.lld', '$stable -> ${versioned[newest]}');
  }

  Map<int, String> versionedLd64Llds() {
    final bin = host.fileSystem.directory('/usr/bin');
    if (!bin.existsSync()) return const {};
    final found = <int, String>{};
    for (final entry in bin.listSync()) {
      if (entry is! File && entry is! Link) continue;
      final match = _versionedLd64Lld.firstMatch(p.basename(entry.path));
      if (match != null) {
        found[int.parse(match.group(1)!)] = host.paths.context.join(
          '/usr/bin',
          p.basename(entry.path),
        );
      }
    }
    return found;
  }

  Future<List<List<String>>> pipxInstallAttempts(
    LinuxPackageManager manager,
  ) async {
    final py = await runner.which('python3') ?? 'python3';
    return <List<String>>[
      ...await manager.installAttempts(
        [manager.pipxPackage],
        runner,
        services.privileges,
      ),
      [py, '-m', 'pip', 'install', '--user', '--break-system-packages', 'pipx'],
      [py, '-m', 'pip', 'install', '--user', 'pipx'],
    ];
  }

  static final _versionedLd64Lld = RegExp(r'^ld64\.lld-(\d+)$');
}
