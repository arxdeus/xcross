@TestOn('!windows')
library;

import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/flutter_packer.dart';
import 'package:xcross/src/shared/flutter/build/internal/runner_binary.dart';
import 'package:xcross/src/shared/flutter/build/ios_native_assets.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';

import '../flutter_test_runtime.dart';

@internal
final class RecordingFlutterPipeline
    implements
        FlutterResolveStep<LinuxHost>,
        FlutterCompileStep<LinuxHost>,
        FlutterLinkStep<LinuxHost>,
        FlutterAssembleStep<LinuxHost> {
  RecordingFlutterPipeline({
    this.failCompilation = false,
    this.replacementRequest,
  });
  final bool failCompilation;
  final FlutterBuildRequest<LinuxHost>? replacementRequest;
  final List<String> events = [];
  final List<FlutterBuildContext<LinuxHost>> contexts = [];
  FlutterCompiledArtifacts? compiled;
  FlutterLinkedArtifacts? linked;

  @override
  Future<FlutterBuildContext<LinuxHost>> resolve(
    FlutterBuildRequest<LinuxHost> request,
  ) async {
    events.add('resolve');
    return FlutterBuildContext(
      request: replacementRequest ?? request,
      flutterRoot: '/configured/flutter',
    );
  }

  FlutterCompileStep<LinuxHost> compiler(
    FlutterBuildContext<LinuxHost> context,
  ) {
    contexts.add(context);
    return this;
  }

  FlutterLinkStep<LinuxHost> linker(FlutterBuildContext<LinuxHost> context) {
    contexts.add(context);
    return this;
  }

  FlutterAssembleStep<LinuxHost> assembler(
    FlutterBuildContext<LinuxHost> context,
  ) {
    contexts.add(context);
    return this;
  }

  @override
  Future<FlutterCompiledArtifacts> compile() async {
    events.add('compile');
    if (failCompilation) throw StateError('compile failed');
    return compiled = const FlutterCompiledArtifacts(
      appFramework: '/app.framework',
      nativeAssets: IosNativeAssetsBuildResult(
        manifestPath: '/assets.yaml',
        frameworks: [],
      ),
    );
  }

  @override
  Future<FlutterLinkedArtifacts> link(
    FlutterCompiledArtifacts artifacts,
  ) async {
    events.add('link');
    expect(artifacts, same(compiled));
    return linked = FlutterLinkedArtifacts(
      compiled: artifacts,
      runner: const RunnerBinary(
        xcframework: '/engine.xcframework',
        runnerBinary: '/runner',
        sdkName: 'iphoneos',
      ),
      extensions: const [],
    );
  }

  @override
  Future<String> assemble(FlutterLinkedArtifacts artifacts) async {
    events.add('assemble');
    expect(artifacts, same(linked));
    return contexts.last.runtime.policy.outputDirectory(
      contexts.last.projectRoot,
    );
  }
}

void main() {
  late Directory project;
  setUp(() {
    project = Directory.systemTemp.createTempSync('xcross_pipeline_');
    File(
      p.join(project.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: before_resolution\n');
  });
  tearDown(() => project.deleteSync(recursive: true));

  FlutterPacker<LinuxHost> packer(RecordingFlutterPipeline pipeline) =>
      FlutterPacker(
        runtime: testIPhoneRuntime(),
        projectRoot: project.path,
        bundleId: 'com.example.demo',
        options: const FlutterBuildOptions(pub: false),
        resolveStep: pipeline,
        compileStep: pipeline.compiler,
        linkStep: pipeline.linker,
        assembleStep: pipeline.assembler,
      );

  test(
    'typed stages preserve artifact, request, runtime and ordering',
    () async {
      final pipeline = RecordingFlutterPipeline();
      final build = packer(pipeline);
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: changed_after_request\n');
      final output = await build.pack();
      expect(pipeline.events, ['resolve', 'compile', 'link', 'assemble']);
      expect(pipeline.contexts, hasLength(3));
      for (final context in pipeline.contexts) {
        expect(context.request, same(build.request));
        expect(context.runtime, same(build.runtime));
        expect(context.appName, 'before_resolution');
        expect(
          context.deploymentTarget.platform,
          same(build.runtime.target.buildPlatform),
        );
      }
      expect(output, build.outputDirectory);
    },
  );

  test('compile failure prevents linking and publication', () async {
    final pipeline = RecordingFlutterPipeline(failCompilation: true);
    await expectLater(packer(pipeline).pack(), throwsStateError);
    expect(pipeline.events, ['resolve', 'compile']);
    expect(pipeline.linked, isNull);
  });

  test('resolver cannot substitute another runtime request', () async {
    final foreign = packer(RecordingFlutterPipeline());
    final pipeline = RecordingFlutterPipeline(
      replacementRequest: foreign.request,
    );
    await expectLater(packer(pipeline).pack(), throwsArgumentError);
    expect(pipeline.events, ['resolve']);
  });
}
