/// Constants for the Kotlin/Native prebuilt toolchain.
abstract final class KotlinNativeConstants {
  /// Directory name prefix for the linux-x86_64 Kotlin/Native prebuilt.
  static const String knDirPrefix = 'kotlin-native-prebuilt-linux-x86_64-';

  /// Default Kotlin/Native version used when none is detected in the project.
  static const String defaultVersion = '2.2.20';

  /// Default root directory where Kotlin/Native toolchains are installed.
  static const String defaultKonanRoot = '/opt/konan';

  /// Filesystem roots searched when locating an installed Kotlin/Native SDK.
  static const List<String> searchRoots = <String>['/opt/konan'];

  /// Maven repository base URL for Kotlin/Native prebuilt artifacts.
  static const String mavenBaseUrl =
      'https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/'
      'kotlin-native-prebuilt';
}
