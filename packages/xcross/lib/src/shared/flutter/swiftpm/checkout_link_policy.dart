import 'package:meta/meta.dart';

@internal
abstract interface class SwiftPmCheckoutGitPolicy {
  String linkText(String text);
  List<String> get checkoutArguments;
  Future<List<String>> cloneConfiguration();
}

@internal
abstract interface class SwiftPmCheckoutFallback {
  Future<bool> materialize(
    String root,
    Map<String, String> links,
    Map<String, String> targets,
    Map<String, String> resolved,
    List<Map<String, Object?>> records,
  );
}
