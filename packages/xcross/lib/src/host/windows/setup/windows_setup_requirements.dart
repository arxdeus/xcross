import 'package:meta/meta.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';

/// Windows installs its requirements through the `setup/<manager>.ps1`
/// script `xcross setup` picks by default (winget, scoop, choco, or direct
/// without a package manager). This is only reached when no script was
/// chosen, so it points at them instead of guessing.
@internal
final class WindowsSetupRequirements implements SetupRequirements {
  const WindowsSetupRequirements();

  static const scriptsUrl = 'https://github.com/arxdeus/xcross/tree/main/setup';

  @override
  Future<void> run() async => throw XcrossError(
    'Windows requirements are installed by a setup script.\n'
    'Run `xcross setup --manager winget|scoop|choco|direct`, or point '
    '`setup:` in your xcross config at one of the scripts in $scriptsUrl.',
  );
}
