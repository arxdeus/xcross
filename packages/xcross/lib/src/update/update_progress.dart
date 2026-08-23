import 'package:cli_kit/cli_kit.dart';

abstract final class UpdatePhases {
  static const release = [
    'Download release archive',
    'Download checksum manifest',
    'Verify archive',
    'Extract release bundle',
    'Install release',
    'Verify installed release',
  ];

  static const source = [
    'Clone repository',
    'Fetch commit',
    'Check out commit',
    'Resolve dependencies',
    'Build xcross',
    'Install source build',
    'Verify installed source build',
  ];
}

final class UpdateProgress {
  UpdateProgress(this.group, this.total);

  final String group;
  final int total;

  int _completed = 0;

  String nextLabel(String action) {
    if (_completed >= total) {
      throw StateError('$group progress already completed');
    }
    _completed++;
    return '$group [$_completed/$total] $action';
  }

  Future<T> run<T>(String action, Future<T> Function() body) =>
      Log.logStep(nextLabel(action), body);
}
