import 'package:meta/meta.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';

/// Windows installs its requirements through `setup/windows.ps1`, which
/// `xcross setup` runs by default. This is only reached when that default is
/// disabled, so it points at the script instead of guessing.
@internal
final class WindowsSetupRequirements implements SetupRequirements {
  const WindowsSetupRequirements();

  static const scriptUrl =
      'https://raw.githubusercontent.com/arxdeus/xcross/main/setup/windows.ps1';

  @override
  Future<void> run() async => throw XcrossError(
    'Windows requirements are installed by a setup script.\n'
    'Point `setup:` in your xcross config at $scriptUrl (or a local copy) '
    'and run `xcross setup` again.',
  );
}
