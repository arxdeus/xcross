import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';

List<String> orderCheckoutLinks(
  Map<String, String> links,
  Map<String, String> resolved,
) {
  final ordered = <String>[];
  final visiting = <String>{};
  void order(String link) {
    if (ordered.contains(link)) return;
    if (!visiting.add(link)) {
      throw FlutterBuildError('Symlink cycle in SwiftPM checkout: $link');
    }
    final target = resolved[link]!;
    if (Directory(target).existsSync())
      for (final nested in links.keys) {
        if (p.isWithin(target, nested)) order(nested);
      }
    visiting.remove(link);
    ordered.add(link);
  }

  for (final link in links.keys) {
    order(link);
  }
  return ordered;
}
