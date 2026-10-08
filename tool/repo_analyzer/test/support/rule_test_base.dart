import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
// ExpectedDiagnostic is not re-exported from the public library.
import 'package:analyzer_testing/src/analysis_rule/pub_package_resolution.dart';

/// Shared base for architecture rule tests.
///
/// Rules classify files by path, so tests write sources to explicit
/// package-relative locations with [check] and [clean].
abstract class ArchitectureRuleTest extends AnalysisRuleTest {
  @override
  bool get addMetaPackageDep => true;

  /// The default `/home/test` root would look like a nested test fixture.
  @override
  String get testPackageRootPath => '$workspaceRootPath/subject';

  /// Package-relative path used when a test does not pass one.
  String get defaultPath => 'lib/src/shared/subject.dart';

  @override
  void setUp() {
    super.setUp();
    _extendMockSdk();
  }

  /// The analyzer mock SDK omits a few ambient members the rules key on, so
  /// splice minimal declarations into the mock `dart:io` and `dart:ffi`.
  void _extendMockSdk() {
    void patch(String relative, Map<String, String> replacements, String tail) {
      final file = sdkRoot.getFolder('lib').getFile(relative);
      var content = file.readAsStringSync();
      if (content.contains(tail)) return;
      for (final MapEntry(:key, :value) in replacements.entries) {
        if (!content.contains(key)) throw StateError('Mock SDK drift: $key');
        content = content.replaceFirst(key, value);
      }
      file.writeAsStringSync('$content\n$tail');
    }

    patch(
      'io/io.dart',
      {
        'abstract final class Platform {':
            'abstract final class Platform {\n'
            '  static String get operatingSystem => throw 0;\n'
            '  static bool get isWindows => throw 0;\n'
            '  static Map<String, String> get environment => throw 0;\n',
        'abstract interface class Directory implements FileSystemEntity {':
            'abstract interface class Directory implements FileSystemEntity {\n'
            '  static Directory get current => throw 0;\n'
            '  static Directory get systemTemp => throw 0;\n',
      },
      '''
IOSink get stdout => throw 0;
IOSink get stderr => throw 0;
abstract interface class Link implements FileSystemEntity {
  factory Link(String path) => throw 0;
}
abstract final class FileStat {
  static FileStat statSync(String path) => throw 0;
}
abstract final class ServerSocket {
  static Future<ServerSocket> bind(Object address, int port) => throw 0;
}
abstract interface class HttpClient {
  factory HttpClient() => throw 0;
}
''',
    );
    patch('ffi/ffi.dart', {
      'class Abi {': 'class Abi {\n  factory Abi.current() => throw 0;\n',
    }, '// xcross mock extensions');
  }

  String _absolute(String relative) =>
      convertPath('$testPackageRootPath/$relative');

  /// Writes a supporting library without asserting on it.
  void support(String relative, String content) =>
      newFile(_absolute(relative), content);

  /// Asserts that [content] at [path] reports [expected].
  Future<void> check(
    String content,
    List<ExpectedDiagnostic> expected, {
    String? path,
  }) async {
    final file = _absolute(path ?? defaultPath);
    newFile(file, content);
    await assertDiagnosticsInFile(file, expected);
  }

  /// Asserts that [content] at [path] reports nothing for this rule.
  Future<void> clean(String content, {String? path}) =>
      check(content, const [], path: path);

  /// Expects one lint for this rule covering the first occurrence of [token]
  /// in [content].
  ///
  /// Occurrences inside the shared [platform] preamble are ignored so tokens
  /// such as `Host` resolve to the fixture body.
  ExpectedDiagnostic at(String content, String token, {int skip = 0}) {
    var offset = content.startsWith(platform) ? platform.length - 1 : -1;
    for (var i = 0; i <= skip; i++) {
      offset = content.indexOf(token, offset + 1);
    }
    if (offset < 0) throw ArgumentError('Missing token: $token');
    return lint(offset, token.length);
  }

  /// Platform contracts shared by many fixtures.
  static const platform = '''
abstract interface class PlatformHostInterface {
  String get name;
  String get architecture;
  String get operatingSystem;
}
abstract interface class WindowsHostInterface implements PlatformHostInterface {}
abstract interface class LinuxHostInterface implements PlatformHostInterface {}
abstract interface class PlatformTargetInterface<T extends PlatformHostInterface> {
  T get host;
}
abstract interface class IosBuildPlatformInterface {
  String get sdkName;
}
''';
}
