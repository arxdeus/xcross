import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';

@internal
final class PosixPipxPath {
  const PosixPipxPath(this.runner);

  final ProcessRunner runner;

  Future<void> ensure(String pipx) async {
    try {
      await runner.runChecked(pipx, ['ensurepath'], label: 'pipx ensurepath');
    } on Object catch (error) {
      runner.log.logWarn(
        'pipx ensurepath failed, add ~/.local/bin to PATH: $error',
      );
    }
  }
}
