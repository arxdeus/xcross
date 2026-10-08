import 'dart:convert';
import 'dart:io';

/// Checks that an xcross build bundled Flutter's framework shaders as
/// compiled Impeller runtime stages.
void main(List<String> arguments) {
  if (arguments.length != 1) {
    throw ArgumentError('Expected the xcross-ios output directory');
  }
  final apps = Directory(arguments.single)
      .listSync()
      .whereType<Directory>()
      .where((directory) => directory.path.endsWith('.app'))
      .toList();
  if (apps.length != 1) {
    throw StateError('Expected one .app, found ${apps.length}');
  }
  final shaders = Directory.fromUri(
    apps.single.uri.resolve('Frameworks/App.framework/flutter_assets/shaders/'),
  );
  for (final name in ['ink_sparkle.frag', 'stretch_effect.frag']) {
    final shader = File.fromUri(shaders.uri.resolve(name));
    if (!shader.existsSync()) {
      throw StateError('Missing compiled shader ${shader.path}');
    }
    final bytes = shader.readAsBytesSync();
    if (bytes.length < 8 || ascii.decode(bytes.sublist(4, 8)) != 'IPLR') {
      throw StateError('${shader.path} is not an Impeller runtime stage');
    }
  }
  final leftovers = shaders
      .listSync()
      .where((entity) => entity.path.endsWith('.spirv'))
      .toList();
  if (leftovers.isNotEmpty) {
    throw StateError('Unexpected SPIR-V outputs: $leftovers');
  }
  stdout.writeln('Verified compiled Flutter shaders: ${shaders.path}');
}
