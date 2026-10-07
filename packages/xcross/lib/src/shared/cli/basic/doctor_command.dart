import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';
import 'package:xcross/src/shared/errors/errors.dart';

@internal
typedef DoctorWriteLine = void Function(String line);

/// `xcross <framework> doctor`: examines [sections] in order, rendering each
/// under one status header, and fails when any check fails.
///
/// Read-only by contract: sections may probe tools and credentials but never
/// build, install, or launch anything.
@internal
final class DoctorCommand extends Command<void> {
  DoctorCommand({
    required this.framework,
    required this.sections,
    required this.log,
    DoctorWriteLine? writeLine,
  }) : _writeLine = writeLine ?? log.logStatus;

  /// Human name of the framework whose requirements are checked.
  final String framework;
  final List<DoctorSection> sections;
  final Log log;
  final DoctorWriteLine _writeLine;

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check $framework build and run requirements without building or '
      'running.';

  @override
  Future<void> run() async {
    final all = <DoctorCheck>[];
    for (final (index, section) in sections.indexed) {
      final checks = await _examine(section);
      all.addAll(checks);
      if (index > 0) _writeLine('');
      _writeLine(formatSection(section.title, checks, log: log));
    }

    final failures = _count(all, DoctorStatus.failure);
    final warnings = _count(all, DoctorStatus.warning);
    final summary = summarize(failures: failures, warnings: warnings);
    _writeLine('');
    if (failures > 0) throw XcrossError(summary);
    final glyph = warnings == 0 ? log.glyph.ok : log.glyph.warn;
    _writeLine('$glyph$summary');
  }

  /// Runs one section behind a spinner on an interactive terminal; a section
  /// that throws reports the error as its only failure instead of aborting
  /// the remaining sections.
  Future<List<DoctorCheck>> _examine(DoctorSection section) async {
    final step = log.ansi.useAnsi && !log.isVerbose
        ? log.beginStep(section.title)
        : null;
    try {
      return await section.examine();
    } on Object catch (error) {
      return [DoctorCheck.failure(section.title, '$error')];
    } finally {
      if (step != null && identical(log.activeStep, step)) log.stopStep();
    }
  }

  static int _count(List<DoctorCheck> checks, DoctorStatus status) =>
      checks.where((check) => check.status == status).length;

  static String summarize({required int failures, required int warnings}) {
    if (failures == 0 && warnings == 0) return 'No issues found.';
    final issues = [
      if (failures > 0) _plural(failures, 'failure'),
      if (warnings > 0) _plural(warnings, 'warning'),
    ];
    return 'Doctor found ${issues.join(' and ')}.';
  }

  static String _plural(int count, String noun) =>
      '$count $noun${count == 1 ? '' : 's'}';

  /// A `[✓] Title` header carrying the worst status in the section, followed
  /// by one aligned row per check with its location dimmed underneath.
  static String formatSection(
    String title,
    List<DoctorCheck> checks, {
    required Log log,
  }) {
    final ansi = log.ansi;
    final (marker, color) = _style(checks.worst, log);
    final lines = [
      '$color[$marker]${ansi.none} ${ansi.bold}$title${ansi.none}',
    ];
    final width = checks.fold(0, (width, check) {
      final length = check.name.length;
      return length > width ? length : width;
    });
    for (final check in checks) {
      lines.add(formatCheck(check, log: log, nameWidth: width));
    }
    return lines.join('\n');
  }

  static String formatCheck(
    DoctorCheck check, {
    required Log log,
    int nameWidth = 0,
  }) {
    final ansi = log.ansi;
    final (marker, color) = _style(check.status, log);
    const indent = '    ';
    final name = check.name.padRight(nameWidth);
    final prefix = '$indent$color$marker${ansi.none} ';
    final path = check.path;
    // A bare "Found" says nothing the location does not, so the location
    // takes its place on the row.
    if (path != null && check.message == 'Found') {
      return '$prefix$name  ${log.dim(path)}';
    }
    final continuation = ' ' * (indent.length + 2 + nameWidth + 2);
    final message = check.message.split('\n').join('\n$continuation');
    final row = '$prefix$name  $message';
    return path == null ? row : '$row\n$continuation${log.dim(path)}';
  }

  static (String, String) _style(DoctorStatus status, Log log) {
    final ansi = log.ansi;
    return switch (status) {
      DoctorStatus.success => ('✓', ansi.green),
      DoctorStatus.warning => ('!', ansi.yellow),
      DoctorStatus.failure => ('✗', ansi.red),
    };
  }
}
