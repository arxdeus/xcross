import 'package:cli_kit/shared/logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/errors/errors.dart';

@internal
final class ComposeModuleSpec {
  const ComposeModuleSpec(this.gradleId, this.diskPath);
  final String gradleId;
  final String diskPath;
  String get leaf => gradleId.split(':').last;
}

@internal
final class GradleKmpMetadataParser {
  const GradleKmpMetadataParser(this.log);
  final Log log;
  List<ComposeModuleSpec> parseIncludedModules(
    String content,
    String projectRoot,
  ) {
    final result = <ComposeModuleSpec>[];
    final include = RegExp(
      r'''(?:^|[;\n\r])\s*include\s*(?:\(([^)]*)\)|([^\r\n;]+))''',
      multiLine: true,
    );
    final quotedModule = RegExp(
      "[\"'](:[A-Za-z0-9_.-]+(?::[A-Za-z0-9_.-]+)*)[\"']",
    );
    for (final includeMatch in include.allMatches(content)) {
      final args = includeMatch.group(1) ?? includeMatch.group(2) ?? '';
      for (final moduleMatch in quotedModule.allMatches(args)) {
        final gradleId = moduleMatch.group(1)!.substring(1);
        result.add(
          ComposeModuleSpec(
            gradleId,
            p.join(projectRoot, gradleId.replaceAll(':', p.separator)),
          ),
        );
      }
    }
    return result;
  }

  bool hasIosTarget(String content, String target) =>
      RegExp('\\b$target\\s*[({]').hasMatch(content);

  bool hasFrameworkBlock(String content) =>
      content.contains('binaries.framework');

  String? _extractBaseName(String content) =>
      RegExp(r'baseName\s*=\s*"([^"]+)"').firstMatch(content)?.group(1);

  ({String baseName, bool isStatic}) frameworkMetadata(
    String content, {
    required String defaultBaseName,
    required String buildFile,
    required String target,
  }) {
    final metadata = _frameworkBlocks(content)
        .map(
          (block) => (
            baseName: _extractBaseName(block) ?? defaultBaseName,
            isStatic: _extractIsStaticFramework([block]),
          ),
        )
        .toSet();
    if (metadata.isEmpty) {
      throw XcrossError(
        'Cannot read binaries.framework metadata in $buildFile for $target. '
        'Use a supported binaries.framework { ... } block.',
      );
    }
    if (metadata.length > 1) {
      final settings = metadata
          .map(
            (value) =>
                'baseName="${value.baseName}", isStatic=${value.isStatic}',
          )
          .join('; ');
      throw XcrossError(
        'Conflicting binaries.framework metadata in $buildFile for $target: '
        '$settings. xcross cannot reliably assign these settings to the selected '
        'target. Use the same literal baseName and isStatic settings across '
        'framework blocks or separate the targets into modules.',
      );
    }
    return metadata.single;
  }

  /// Whether the module's framework is declared static.
  ///
  /// Scoped to the `binaries.framework { … }` block rather than matched across
  /// the whole script, because `isStatic` is not unique to it: an `xcframework`
  /// block, a second target's framework, or a commented-out line would otherwise
  /// all turn it on. Getting this wrong is not symmetric - a false positive stages
  /// an app with no framework embedded at all, which only fails once the app is
  /// launched on a device.
  ///
  /// Both assignment styles Gradle accepts are recognised (`isStatic = true` in
  /// Kotlin DSL, `isStatic.set(true)` via the property API).
  bool _extractIsStaticFramework(Iterable<String> blocks) {
    for (final block in blocks) {
      if (RegExp(
        r'isStatic\s*(?:=\s*true\b|\.set\s*\(\s*true\s*\))',
      ).hasMatch(block)) {
        return true;
      }
      final computed = RegExp(
        r'isStatic\s*(?:=\s*(?!true\b|false\b)|\.set\s*\(\s*(?!true\b|false\b))',
      ).hasMatch(block);
      if (computed) {
        log.logWarn(
          'isStatic in binaries.framework is not a literal true/false, so xcross '
          'treats the framework as dynamic. Use a literal value if it is static.',
        );
      }
    }
    return false;
  }

  /// [content] with `//` and `/* */` comments removed, leaving string literals
  /// intact.
  String stripComments(String content) {
    final out = StringBuffer();
    var i = 0;
    while (i < content.length) {
      final char = content[i];
      final next = i + 1 < content.length ? content[i + 1] : '';
      if (char == '"') {
        final end = _stringEnd(content, i);
        out.write(content.substring(i, end));
        i = end;
      } else if (char == '/' && next == '/') {
        final end = content.indexOf('\n', i);
        i = end < 0 ? content.length : end;
      } else if (char == '/' && next == '*') {
        final end = content.indexOf('*/', i + 2);
        i = end < 0 ? content.length : end + 2;
        out.write(' ');
      } else {
        out.write(char);
        i++;
      }
    }
    return out.toString();
  }

  int _stringEnd(String content, int start) {
    if (content.startsWith('"""', start)) {
      final end = content.indexOf('"""', start + 3);
      return end < 0 ? content.length : end + 3;
    }
    for (var i = start + 1; i < content.length; i++) {
      if (content[i] == r'\') {
        i++;
      } else if (content[i] == '"' || content[i] == '\n') {
        return i + 1;
      }
    }
    return content.length;
  }

  /// The body of every `binaries.framework { … }` block, brace-matched.
  ///
  /// Returns null when the block is absent or its braces do not close, so a script
  /// this cannot read is treated as "not static", the safe default.
  Iterable<String> _frameworkBlocks(String content) sync* {
    final starts = RegExp(
      r'binaries\.framework\s*(?:\([^)]*\)\s*)?\{',
    ).allMatches(content);
    for (final start in starts) {
      var depth = 0;
      for (var i = start.end - 1; i < content.length; i++) {
        final char = content[i];
        if (char == '"') {
          i = _stringEnd(content, i) - 1;
          continue;
        }
        if (char == '{') depth++;
        if (char == '}') {
          depth--;
          if (depth == 0) {
            yield content.substring(start.end, i);
            break;
          }
        }
      }
    }
  }
}
