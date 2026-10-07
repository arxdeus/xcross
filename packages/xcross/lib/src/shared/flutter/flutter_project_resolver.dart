import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';

@internal
final class FlutterProjectResolver<T extends PlatformHostInterface>
    implements FlutterResolveStep<T> {
  FlutterProjectResolver(this.runtime);
  final FlutterBuildRuntime<T> runtime;
  Future<String> resolveFlutterRoot({
    required String projectRoot,
    String? root,
  }) async {
    final configuration = runtime.resolution;
    final paths = runtime.host.paths.context;
    final fileSystem = runtime.host.fileSystem;
    final selectedRoot = root ?? configuration.root;
    if (selectedRoot != null && selectedRoot.isNotEmpty) return selectedRoot;
    final environmentRoot = configuration.environmentRoot;
    if (environmentRoot != null && environmentRoot.isNotEmpty) {
      return environmentRoot;
    }
    if (!configuration.declarative) {
      final inherited = runtime.runner.environmentValue(
        runtime.runner.effectiveEnvironment,
        'FLUTTER_ROOT',
      );
      if (inherited != null && inherited.isNotEmpty) return inherited;
    }
    final fvm = paths.join(projectRoot, '.fvm', 'flutter_sdk');
    if (fileSystem.directory(fvm).existsSync() ||
        fileSystem.link(fvm).existsSync()) {
      return fileSystem.link(fvm).resolveSymbolicLinksSync();
    }
    final flutter = configuration.tool;
    if (configuration.declarative && (flutter == null || flutter.isEmpty)) {
      throw FlutterBuildError(
        'Flutter SDK not configured. Set roots.flutterSdk, environment FLUTTER_ROOT, tools.flutter, or add .fvm/flutter_sdk to the project.',
      );
    }
    final located = flutter ?? await runtime.runner.locateTool('flutter');
    final executable = fileSystem.file(located);
    final sdkRoot = await runtime.sdkHostPolicy.rootFromExecutable(
      executable.existsSync() ? executable.resolveSymbolicLinksSync() : located,
      runtime.runner,
    );
    return sdkRoot;
  }

  @override
  Future<FlutterBuildContext<T>> resolve(FlutterBuildRequest<T> request) async {
    if (!identical(runtime, request.runtime)) {
      throw ArgumentError('Flutter request and resolver must share a runtime');
    }
    request.options.validate();
    final root = await resolveFlutterRoot(projectRoot: request.projectRoot);
    runtime.runner.log.logTrace('Flutter SDK: $root');
    if (request.options.pub) {
      await runtime.runner.log.logStep('Resolving dependencies', () async {
        try {
          await runtime.runner.runChecked(
            runtime.host.paths.context.join(
              root,
              'bin',
              runtime.runner.hostExecutableName('flutter', extension: '.bat'),
            ),
            ['pub', 'get'],
            workingDirectory: request.projectRoot,
            inheritStdio: runtime.runner.log.isVerbose,
            label: 'flutter',
          );
        } on FlutterBuildError {
          if (await runtime.packageConfigs.find(request.projectRoot) != null) {
            runtime.runner.log.logWarn(
              'Ignoring flutter pub get error because package_config.json exists.',
            );
            return;
          }
          rethrow;
        }
      });
    } else {
      runtime.runner.log.logTrace('skipping flutter pub get (--no-pub)');
    }
    if (request.options.flavor != null) {
      runtime.runner.log.logTrace(
        'building flavor "${request.options.flavor}"',
      );
    }
    final context = FlutterBuildContext(request: request, flutterRoot: root);
    runtime.runner.log.logTrace(
      'iOS deployment target: ${context.deploymentTarget.version}',
    );
    return context;
  }
}
