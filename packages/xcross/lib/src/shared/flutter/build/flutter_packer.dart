import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/flutter_artifact_compiler.dart';
import 'package:xcross/src/shared/flutter/flutter_artifact_linker.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/flutter_bundle_assembler.dart';
import 'package:xcross/src/shared/flutter/flutter_project_resolver.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';

@internal
final class FlutterPacker<T extends PlatformHostInterface> {
  FlutterPacker({
    required FlutterBuildRuntime<T> runtime,
    required String projectRoot,
    required String bundleId,
    required FlutterBuildOptions options,
    bool swiftPmArtifactJunctionCapability = false,
    bool packageLocalArtifactJunctionCapability = false,
    ArtifactJunctionCapabilityResolver? artifactJunctionCapabilityResolver,
    FlutterResolveStep<T>? resolveStep,
    FlutterCompileStep<T> Function(FlutterBuildContext<T>)? compileStep,
    FlutterLinkStep<T> Function(FlutterBuildContext<T>)? linkStep,
    FlutterAssembleStep<T> Function(FlutterBuildContext<T>)? assembleStep,
  }) : request = FlutterBuildRequest(
         runtime: runtime,
         projectRoot: projectRoot,
         bundleId: bundleId,
         options: options,
         swiftPmArtifactJunctionCapability: swiftPmArtifactJunctionCapability,
         packageLocalArtifactJunctionCapability:
             packageLocalArtifactJunctionCapability,
         artifactJunctionCapabilityResolver: artifactJunctionCapabilityResolver,
       ),
       _resolve = resolveStep ?? FlutterProjectResolver(runtime),
       _compile = compileStep ?? FlutterArtifactCompiler.new,
       _link = linkStep ?? FlutterArtifactLinker.new,
       _assemble = assembleStep ?? FlutterBundleAssembler.new;
  final FlutterBuildRequest<T> request;
  final FlutterResolveStep<T> _resolve;
  final FlutterCompileStep<T> Function(FlutterBuildContext<T>) _compile;
  final FlutterLinkStep<T> Function(FlutterBuildContext<T>) _link;
  final FlutterAssembleStep<T> Function(FlutterBuildContext<T>) _assemble;
  FlutterBuildRuntime<T> get runtime => request.runtime;
  String get projectRoot => request.projectRoot;
  String get bundleId => request.bundleId;
  FlutterBuildOptions get options => request.options;
  String get appName => request.appName;
  String get outputDirectory => runtime.policy.outputDirectory(projectRoot);
  Future<String> resolveFlutterRoot({String? root}) => FlutterProjectResolver(
    runtime,
  ).resolveFlutterRoot(projectRoot: projectRoot, root: root);
  Future<String> pack() async {
    options.validate();
    final context = await _resolve.resolve(request);
    if (!identical(context.request, request)) {
      throw ArgumentError('Flutter resolver must retain the original request');
    }
    final compiled = await _compile(context).compile();
    final linked = await _link(context).link(compiled);
    final assembled = await _assemble(context).assemble(linked);
    return assembled;
  }
}
