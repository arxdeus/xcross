import 'package:meta/meta.dart';

@internal
enum DoctorStatus { success, warning, failure }

@internal
final class DoctorCheck {
  const DoctorCheck(this.status, this.name, this.message, {this.path});

  const DoctorCheck.success(this.name, this.message, {this.path})
    : status = DoctorStatus.success;
  const DoctorCheck.warning(this.name, this.message, {this.path})
    : status = DoctorStatus.warning;
  const DoctorCheck.failure(this.name, this.message, {this.path})
    : status = DoctorStatus.failure;

  final DoctorStatus status;
  final String name;
  final String message;
  final String? path;
}

@internal
enum DoctorProjectKind { flutter, compose }

@internal
final class DoctorProject {
  const DoctorProject(this.kind, this.root);

  const DoctorProject.flutter(this.root) : kind = DoctorProjectKind.flutter;
  const DoctorProject.compose(this.root) : kind = DoctorProjectKind.compose;

  final DoctorProjectKind kind;
  final String root;
}
