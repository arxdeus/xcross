import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The result of compiling one `.xib`: the `.nib` `ibtool --compile` writes,
/// or the reasons it could not be reproduced faithfully.
@internal
@immutable
final class XibCompilation {
  const XibCompilation.compiled(Uint8List this.nib) : unsupported = const [];

  const XibCompilation.unsupported(this.unsupported) : nib = null;

  /// The compiled `NIBArchive`, or null when [unsupported] is not empty.
  final Uint8List? nib;

  /// Human readable descriptions of the elements or attributes that stopped
  /// compilation (`<tableView>`, `button type="detailDisclosure"`, ...).
  final List<String> unsupported;
}

/// Pure-Dart `ibtool --compile` for iOS `.xib` files, as Xcode runs it for
/// a SwiftPM `.process` resource: `--module` set to the target, both device
/// families, and the target's minimum deployment version.
@internal
final class XibCompiler {
  const XibCompiler();

  /// Compiles the [xml] of a `.xib`. [module] is the target's module name
  /// (`customModuleProvider="target"` classes resolve against it) and
  /// [deploymentTarget] the iOS version the target is built for.
  XibCompilation compile(
    String xml, {
    required String module,
    required String deploymentTarget,
  }) => const XibCompilation.unsupported([
    'xib compilation is not implemented yet',
  ]);
}
