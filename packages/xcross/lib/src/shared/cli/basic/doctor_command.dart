import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_util/cli_logging.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/basic/doctor_examiner.dart';
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';
import 'package:xcross/src/shared/errors/errors.dart';

@internal
typedef DoctorExamine = Future<List<DoctorCheck>> Function();
@internal
typedef DoctorWriteLine = void Function(String line);

@internal
final class DoctorCommand extends Command<void> {
  DoctorCommand(DoctorExaminer examiner, {required Log log})
    : this.withSeams(
        examine: examiner.examine,
        writeLine: log.logStatus,
        log: log,
      );

  DoctorCommand.withSeams({
    required this.log,
    required DoctorExamine examine,
    required DoctorWriteLine writeLine,
  }) : _examine = examine,
       _writeLine = writeLine;

  final Log log;
  final DoctorExamine _examine;
  final DoctorWriteLine _writeLine;

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check build and run requirements without building or running.';

  @override
  Future<void> run() async {
    final checks = await _examine();
    for (final check in checks) {
      _writeLine(formatCheck(check, ansi: log.ansi));
    }

    final failures = _count(checks, DoctorStatus.failure);
    if (failures > 0) {
      throw XcrossError(_summary(failures, 'failure'));
    }

    final warnings = _count(checks, DoctorStatus.warning);
    _writeLine(
      warnings == 0 ? 'No issues found.' : _summary(warnings, 'warning'),
    );
  }

  static int _count(List<DoctorCheck> checks, DoctorStatus status) =>
      checks.where((check) => check.status == status).length;

  static String _summary(int count, String issue) =>
      'Doctor found $count $issue${count == 1 ? '' : 's'}.';

  static String formatCheck(
    DoctorCheck check, {
    required Ansi ansi,
    String Function(String value)? dim,
  }) {
    final (marker, color) = switch (check.status) {
      DoctorStatus.success => ('✓', ansi.green),
      DoctorStatus.warning => ('!', ansi.yellow),
      DoctorStatus.failure => ('✗', ansi.red),
    };
    final line = '$color[$marker]${ansi.none} ${check.name}: ${check.message}';
    if (check.path case final path?) {
      return '$line\n    ${(dim ?? ((value) => value))(path)}';
    }
    return line;
  }
}
