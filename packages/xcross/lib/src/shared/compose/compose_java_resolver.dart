import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/compose/compose_process_contracts.dart';

final class ComposeJava {
  const ComposeJava(this.home, this.executable);
  final String home;
  final String executable;
}

final class ComposeJavaResolver<T extends PlatformHostInterface> {
  const ComposeJavaResolver(this._which, this._run);
  final ComposeWhich _which;
  final ComposeRun _run;
  Future<ComposeJava?> resolve(
    ComposeHost<T> host,
    Map<String, String> environment,
    List<String> problems,
  ) async {
    final javaHome = environment['JAVA_HOME'];
    final candidate = javaHome == null
        ? await _which('java', environment: environment)
        : host.javaExecutable(javaHome);
    if (candidate == null) {
      problems.add(
        'Missing JDK 21+. Set JAVA_HOME to a JDK 21+ install or put java on PATH.',
      );
      return null;
    }
    final result = await _run(candidate, const [
      '-XshowSettings:properties',
      '-version',
    ], environment: environment);
    final output = '${result.stdout}\n${result.stderr}';
    final version = RegExp(r'version "(\d+)').firstMatch(output)?.group(1);
    if (result.exitCode != 0 || version == null || int.parse(version) < 21) {
      problems.add(
        'Missing JDK 21+. Found java at $candidate but it is not Java 21+.',
      );
      return null;
    }
    final architecture = RegExp(
      r'^\s*os\.arch\s*=\s*(\S+)',
      multiLine: true,
    ).firstMatch(output)?.group(1);
    if (architecture == null || !host.supportsJavaArchitecture(architecture)) {
      problems.add(
        'JDK architecture ${architecture ?? 'unknown'} does not match '
        'Kotlin/Native host ${host.classifier}. Set JAVA_HOME to a matching '
        'JDK 21+ install so its JNI libraries can load.',
      );
      return null;
    }
    if (javaHome != null) return ComposeJava(javaHome, candidate);
    final reportedHome = RegExp(
      r'^[ \t]*java\.home[ \t]*=[ \t]*([^\r\n]*)',
      multiLine: true,
    ).firstMatch(output)?.group(1)?.trim();
    if (reportedHome == null ||
        !p.isAbsolute(reportedHome) ||
        !host.host.fileSystem
            .file(host.javaExecutable(reportedHome))
            .existsSync()) {
      problems.add(
        'Cannot determine a valid JDK home from java.home reported by '
        '$candidate. Set JAVA_HOME to a JDK 21+ install containing bin/'
        '${p.basename(host.javaExecutable(''))}.',
      );
      return null;
    }
    return ComposeJava(reportedHome, candidate);
  }
}
