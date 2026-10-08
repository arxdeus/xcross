import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/compose_host.dart';

@internal
const kotlinNativeMavenBase =
    'https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-native-prebuilt';

@internal
final class ComposeSetupOptions<T extends PlatformHostInterface> {
  const ComposeSetupOptions({
    required this.host,
    required this.version,
    required this.projectRoot,
    required this.cacheRoot,
    required this.kotlinHome,
    required this.konanCache,
    required this.hostArchiveUrl,
    required this.overlayArchiveUrl,
    required this.hostArchiveSha256,
    required this.overlayArchiveSha256,
    this.environment = const {},
  });

  static const defaultKotlinNativeVersion = '2.2.20';

  final ComposeHost<T> host;
  final String version;
  final String projectRoot;
  final String cacheRoot;
  final String kotlinHome;
  final String konanCache;
  final String hostArchiveUrl;
  final String? overlayArchiveUrl;
  final String? hostArchiveSha256;
  final String? overlayArchiveSha256;
  final Map<String, String> environment;

  static ComposeSetupOptions<T> resolve<T extends PlatformHostInterface>({
    required Map<String, String> env,
    required String projectRoot,
    required ComposeHost<T> host,
    String? cacheRootOverride,
  }) {
    final version = _version(env, projectRoot, host.host.fileSystem);
    final configuredRoot =
        _nonEmpty(cacheRootOverride) ??
        _nonEmpty(env['KONAN_DATA_DIR']) ??
        _nonEmpty(env['XCROSS_KONAN_DATA_DIR']);
    final cacheRoot =
        configuredRoot ??
        p.join(
          _nonEmpty(env['HOME']) ?? _nonEmpty(env['USERPROFILE']) ?? '.',
          '.konan',
        );
    return ComposeSetupOptions(
      host: host,
      version: version,
      environment: Map.unmodifiable(env),
      projectRoot: projectRoot,
      cacheRoot: cacheRoot,
      kotlinHome: p.join(
        cacheRoot,
        'kotlin-native-prebuilt-${host.classifier}-$version',
      ),
      konanCache: p.join(cacheRoot, 'cache'),
      hostArchiveUrl:
          '$kotlinNativeMavenBase/$version/${host.hostArtifact(version)}',
      overlayArchiveUrl: host
          .installationArtifacts(version)
          .skip(1)
          .map((artifact) => '$kotlinNativeMavenBase/$version/$artifact')
          .firstOrNull,
      hostArchiveSha256: _sha256ByArtifact[host.hostArtifact(version)],
      overlayArchiveSha256:
          _sha256ByArtifact[host
              .installationArtifacts(version)
              .skip(1)
              .firstOrNull],
    );
  }

  static const Map<String, String> _sha256ByArtifact = {
    'kotlin-native-prebuilt-2.2.20-linux-x86_64.tar.gz':
        '5e2c25c7783f2a7f89aafeb3ccfb0fb5a671e0e32d283c3ab335dc5e29f19e32',
    'kotlin-native-prebuilt-2.2.20-windows-x86_64.zip':
        '2bf86caed1b5a67f0cd15c685cb8584a2e61f3221d0985f4fc6a590f51c398df',
    'kotlin-native-prebuilt-2.2.20-macos-x86_64.tar.gz':
        'ca9eb2dbb87703176bdbafaad887dc5036c9e5dbfd2eec113b7f4f4a346ca60b',
    'kotlin-native-prebuilt-2.2.20-macos-aarch64.tar.gz':
        '2acd3a2e0e5a9782b5cc2cb90c18f2412eda86ab3fb8adf2d18a3e3ca9b80ee6',
    'kotlin-native-prebuilt-2.4.0-linux-x86_64.tar.gz':
        '1fdad03264fc398d24df961bf6563e35b82706bb67cf3ba926eb7b768ce7d536',
    'kotlin-native-prebuilt-2.4.0-windows-x86_64.zip':
        'cf91af2dbe53767ec89d0eb0f744e588f316a8d115e5faba401ae3f2db7db535',
    'kotlin-native-prebuilt-2.4.0-macos-x86_64.tar.gz':
        'da0684965d6f33c55b5e6e85b6de8a5327dbd3ccfedcb1ab6c1131900e8b3e83',
    'kotlin-native-prebuilt-2.4.0-macos-aarch64.tar.gz':
        '9ef8c0f9fd90f4082d6e62f14655d23d81651d89d49205e5c49177ff34f552b8',
  };

  static String? _nonEmpty(String? value) =>
      value != null && value.trim().isNotEmpty ? value : null;

  static String _version(
    Map<String, String> env,
    String projectRoot,
    HostFileSystemInterface files,
  ) {
    final explicit = env['KN_VERSION'];
    if (explicit != null && explicit.trim().isNotEmpty) return explicit.trim();

    final catalog = files.file(
      p.join(projectRoot, 'gradle', 'libs.versions.toml'),
    );
    if (catalog.existsSync()) {
      final match = RegExp(
        r'''(?:^|\n)\s*(?:kotlin|kotlinNative|kotlin-native)\s*=\s*["']([^"']+)["']''',
      ).firstMatch(catalog.readAsStringSync());
      if (match != null) return match.group(1)!;
    }

    final properties = files.file(p.join(projectRoot, 'gradle.properties'));
    if (properties.existsSync()) {
      for (final line in properties.readAsLinesSync()) {
        final match = RegExp(
          r'^\s*(?:kotlin\.version|kotlinNative\.version)\s*=\s*(\S+)',
        ).firstMatch(line);
        if (match != null) return match.group(1)!;
      }
    }

    return defaultKotlinNativeVersion;
  }
}
