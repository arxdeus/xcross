import 'package:cli_util/cli_logging.dart';

Logger _logger = Logger.standard();

/// Switch global logger to verbose mode (shows trace output).
void setVerbose() => _logger = Logger.verbose();

/// A status/progress line.
void logStatus(String message) => _logger.stdout(message);

/// A `warning: ...` line on stderr.
void logWarn(String message) {
  final ansi = _logger.ansi;
  _logger.stderr('${ansi.yellow}warning:${ansi.none} $message');
}

/// An `error: ...` line on stderr.
void logError(String message) {
  final ansi = _logger.ansi;
  _logger.stderr('${ansi.red}error:${ansi.none} $message');
}
