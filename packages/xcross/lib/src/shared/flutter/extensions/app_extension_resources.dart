import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_app_extensions.dart';

final class AppExtensionResources {
  AppExtensionResources({required this.fileSystem, required this.log});
  final HostFileSystemInterface fileSystem;
  final Log log;
  String replaceStoryboardWithPrincipalClass(
    String xml, {
    required IosAppExtension extension,
  }) {
    final storyboard = RegExp(
      r'\s*<key>\s*NSExtensionMainStoryboard\s*</key>\s*<string>([^<]*)</string>',
    ).firstMatch(xml);
    if (storyboard == null) return xml;

    final principalClass = _principalClassFor(
      extension,
      storyboardName: storyboard.group(1)!.trim(),
    );
    if (principalClass == null) {
      log.logWarn(
        'App extension "${extension.name}" uses a storyboard that could not '
        'be resolved to a view controller class; it may not launch.',
      );
      return xml;
    }

    log.logTrace(
      '${extension.name}: NSExtensionMainStoryboard → '
      'NSExtensionPrincipalClass $principalClass',
    );
    return xml.replaceRange(
      storyboard.start,
      storyboard.end,
      '\n\t\t<key>NSExtensionPrincipalClass</key>'
      '\n\t\t<string>$principalClass</string>',
    );
  }

  /// The `<module>.<class>` principal class for [extension], read from the
  /// storyboard's initial view controller `customClass`, falling back to the
  /// only view-controller-shaped Swift source file name.
  String? _principalClassFor(
    IosAppExtension extension, {
    required String storyboardName,
  }) {
    final storyboard = extension.resources.firstWhere(
      (resource) =>
          p.basenameWithoutExtension(resource) == storyboardName &&
          resource.endsWith('.storyboard'),
      orElse: () => '',
    );

    String? className;
    if (storyboard.isNotEmpty && fileSystem.file(storyboard).existsSync()) {
      className = RegExp(
        'customClass="([^"]+)"',
      ).firstMatch(fileSystem.file(storyboard).readAsStringSync())?.group(1);
    }
    className ??= extension.sources
        .map(p.basenameWithoutExtension)
        .where((name) => name.endsWith('ViewController'))
        .firstOrNull;
    if (className == null) return null;

    // An @objc class keeps its bare ObjC name; a plain Swift class is
    // mangled as <module>.<class>, which is what Xcode writes here.
    return '${extension.moduleName}.$className';
  }

  /// Copy the extension's resources into the bundle.
  ///
  /// Storyboards and asset catalogs need `ibtool`/`actool`, which are macOS
  /// only, so uncompiled `.storyboard`/`.xcassets` inputs are skipped with a
  /// warning rather than shipped in a form iOS cannot read. A precompiled
  /// `.storyboardc`/`.car` sitting next to the source is used when present.
  Future<void> copyResources({
    required IosAppExtension extension,
    required String bundleDir,
  }) async {
    for (final resource in extension.resources) {
      final name = p.basename(resource);
      // Localized resources keep their `<lang>.lproj` directory: it is how
      // iOS selects a language, and flattening it would also make every
      // language's copy of a file collide on one bundle-root name.
      final destination = p.joinAll([bundleDir, ?_lprojOf(resource), name]);
      if (name.endsWith('.storyboard')) {
        // Handled by replaceStoryboardWithPrincipalClass above.
        final compiled = '${p.withoutExtension(resource)}.storyboardc';
        if (fileSystem.directory(compiled).existsSync()) {
          await _copyDirectory(
            compiled,
            p.join(p.dirname(destination), p.basename(compiled)),
          );
        } else {
          log.logWarn(
            'Skipping "${extension.name}" storyboard $name: compiling '
            'storyboards needs ibtool (macOS only). The extension will use '
            'its principal class instead.',
          );
        }
        continue;
      }
      if (name.endsWith('.xcassets')) {
        log.logWarn(
          'Skipping "${extension.name}" asset catalog $name: compiling asset '
          'catalogs needs actool (macOS only).',
        );
        continue;
      }

      if (fileSystem.directory(resource).existsSync()) {
        await _copyDirectory(resource, destination);
      } else if (fileSystem.file(resource).existsSync()) {
        await fileSystem
            .directory(p.dirname(destination))
            .create(recursive: true);
        await fileSystem.file(resource).copy(destination);
      }
    }
  }

  /// The `<lang>.lproj` directory [resource] sits in, or null when it is not
  /// a localized resource.
  static String? _lprojOf(String resource) {
    final parent = p.basename(p.dirname(resource));
    return parent.endsWith('.lproj') ? parent : null;
  }

  Future<void> _copyDirectory(String src, String dst) async {
    await fileSystem.directory(dst).create(recursive: true);
    await for (final entity in fileSystem.directory(src).list()) {
      final destPath = p.join(dst, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity.path, destPath);
      } else if (entity is File) {
        await entity.copy(destPath);
      }
    }
  }
}
