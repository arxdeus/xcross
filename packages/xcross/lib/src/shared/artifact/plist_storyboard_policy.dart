import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

@internal
final class PlistStoryboardPolicy {
  PlistStoryboardPolicy(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  String stripUnsatisfiableStoryboards(String xml, String bundleDir) {
    // NSBundle resolves a storyboard from the bundle root or, as Xcode lays
    // it out, from `Base.lproj` (and the other `.lproj` directories).
    bool hasCompiled(String name) {
      final compiled = '$name.storyboardc';
      if (fileSystem.directory(paths.join(bundleDir, compiled)).existsSync()) {
        return true;
      }
      final bundle = fileSystem.directory(bundleDir);
      if (!bundle.existsSync()) return false;
      return bundle
          .listSync(followLinks: false)
          .any(
            (entity) =>
                paths.extension(entity.path) == '.lproj' &&
                fileSystem
                    .directory(paths.join(entity.path, compiled))
                    .existsSync(),
          );
    }

    // Named local reused by Main and Scene patterns (identical predicate).
    String keepIfCompiled(Match m) =>
        hasCompiled(m.group(1)!) ? m.group(0)! : '';

    var result = xml.replaceAllMapped(_uiMainStoryboardPattern, keepIfCompiled);

    result = result.replaceAllMapped(_uiLaunchStoryboardPattern, (m) {
      if (hasCompiled(m.group(1)!)) {
        return m.group(0)!;
      }
      // Replace with UILaunchScreen programmatic launch screen if absent.
      // Reads the pre-launch-strip snapshot of `result` on purpose: hoisting
      // this check or chaining the replaceAllMapped calls changes which
      // snapshot is inspected and can emit a duplicate UILaunchScreen.
      if (!result.contains('UILaunchScreen')) {
        return '<key>UILaunchScreen</key>\n\t<dict/>';
      }
      return '';
    });

    result = result.replaceAllMapped(_uiSceneStoryboardPattern, keepIfCompiled);

    return result;
  }

  static final _uiMainStoryboardPattern = RegExp(
    r'<key>UIMainStoryboardFile</key>\s*<string>([^<]*)</string>',
  );

  static final _uiLaunchStoryboardPattern = RegExp(
    r'<key>UILaunchStoryboardName</key>\s*<string>([^<]*)</string>',
  );

  static final _uiSceneStoryboardPattern = RegExp(
    r'<key>UISceneStoryboardFile</key>\s*<string>([^<]*)</string>',
  );
}
