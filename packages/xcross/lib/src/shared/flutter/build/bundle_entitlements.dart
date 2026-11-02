import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/shared/signing/adhoc_signer.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/shared/flutter/build/pbxproj.dart';
import 'package:xcross/src/shared/flutter/project/pbx_project_reader.dart';

/// One executable to sign ad-hoc with the entitlements its target declares.
@internal
@immutable
final class EntitledExecutable {
  const EntitledExecutable({
    required this.bundlePath,
    required this.executableName,
    required this.identifier,
    required this.entitlements,
  });

  /// The `.app` or `.appex` directory holding the executable and Info.plist.
  final String bundlePath;
  final String executableName;

  /// `CFBundleIdentifier`, used as the code-signing identifier.
  final String identifier;
  final Map<String, Object?> entitlements;
}

/// Embeds a Flutter project's `CODE_SIGN_ENTITLEMENTS` into the ad-hoc code
/// signatures of the built app (issue #149).
///
/// xcross does not sign `flutter build` output, but every external re-signer
/// (Sideloadly, AltStore, zsign, `fastlane resign`) takes the entitlements it
/// applies from the binary's existing signature. Linker-signed ad-hoc
/// signatures carry none, so push and associated domains were silently lost.
///
/// The same signature is also the hand-off to `xcross flutter run`:
/// `AppEntitlements`/`AppCapabilities` read the entitlements back from it, so a
/// Flutter bundle never needs private `Info.plist` keys that would otherwise
/// ship inside an unsigned `.ipa`.
///
/// Variables: `$(PRODUCT_BUNDLE_IDENTIFIER)` and any setting of the target's
/// build configuration are expanded. `$(AppIdentifierPrefix)` and
/// `$(TeamIdentifierPrefix)` need a team, which a build does not have; a value
/// still containing `$(` is dropped (an array keeps its other elements) and
/// reported, because a literal `$(…)` is never valid and installd rejects it.
/// Those values are team-scoped (keychain groups, iCloud containers), and the
/// re-signer or xcross's own signer supplies them from the profile.
@internal
final class BundleEntitlements {
  BundleEntitlements({
    required this.fileSystem,
    required this.paths,
    required this.projects,
    required this.log,
  });

  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final PbxProjectReader projects;
  final Log log;

  static const _applicationType = 'com.apple.product-type.application';
  static const _extensionType = 'com.apple.product-type.app-extension';

  /// The executables of [bundleDir] (the staged `.app`) that need entitlements
  /// embedded: the app's own, and each `PlugIns/<Name>.appex` whose target
  /// declares an entitlements file. [configuration] is the Xcode build
  /// configuration to read settings from (`Debug`, `Profile`, `Release`).
  List<EntitledExecutable> resolve({
    required String projectRoot,
    required String bundleDir,
    required String configuration,
  }) {
    final pbxproj = projects.findPbxproj(projectRoot);
    if (pbxproj == null) return const [];
    final project = projects.parseFile(pbxproj);
    if (project == null) return const [];

    final result = <EntitledExecutable>[];
    var sawApplication = false;
    for (final target in project.nativeTargets) {
      final type = target.string('productType');
      final String bundlePath;
      if (type == _applicationType) {
        // The first application target is the one Flutter builds.
        if (sawApplication) continue;
        sawApplication = true;
        bundlePath = bundleDir;
      } else if (type == _extensionType) {
        final name = target.string('name') ?? target.string('productName');
        if (name == null) continue;
        bundlePath = paths.join(bundleDir, 'PlugIns', '$name.appex');
      } else {
        continue;
      }
      if (!fileSystem.directory(bundlePath).existsSync()) continue;
      final executable = _executable(
        target,
        project,
        bundlePath,
        configuration,
      );
      if (executable != null) result.add(executable);
    }
    return result;
  }

  EntitledExecutable? _executable(
    PbxObject target,
    PbxProject project,
    String bundlePath,
    String configuration,
  ) {
    final settings = project.buildSettings(
      target,
      preferredConfiguration: configuration,
    );
    final declaredPath = settings['CODE_SIGN_ENTITLEMENTS'];
    if (declaredPath is! String || declaredPath.trim().isEmpty) return null;

    final info = _infoPlist(bundlePath);
    if (info == null) return null;
    final identifier = info['CFBundleIdentifier'];
    final executableName =
        info['CFBundleExecutable'] as String? ??
        paths.basenameWithoutExtension(bundlePath);
    if (identifier is! String || identifier.isEmpty) return null;

    final variables = <String, String>{
      for (final entry in settings.entries)
        if (entry.value case final String value) entry.key: value,
      'PRODUCT_BUNDLE_IDENTIFIER': identifier,
      'TARGET_NAME': ?target.string('name'),
      'CONFIGURATION': configuration,
    };
    final resolvedPath = _expand(declaredPath, variables);
    final absolute = paths.isAbsolute(resolvedPath)
        ? resolvedPath
        : paths.normalize(paths.join(project.projectDirectory, resolvedPath));
    final rel = paths.relative(bundlePath, from: paths.dirname(bundlePath));
    if (resolvedPath.contains(r'$(')) {
      log.logWarn(
        'Entitlements of $rel were not embedded: CODE_SIGN_ENTITLEMENTS '
        '"$declaredPath" uses an unknown build setting.',
      );
      return null;
    }
    final declared = _readPlist(absolute, rel);
    if (declared == null) return null;

    final dropped = <String>[];
    final entitlements = <String, Object?>{};
    for (final entry in declared.entries) {
      final value = _expandValue(entry.value, variables);
      if (value == null) {
        dropped.add(entry.key);
      } else {
        entitlements[entry.key] = value;
      }
    }
    if (dropped.isNotEmpty) {
      log.logTrace(
        'not embedding team-scoped entitlement values of $rel '
        '(need a signing team): ${dropped.join(', ')}',
      );
    }
    return EntitledExecutable(
      bundlePath: bundlePath,
      executableName: executableName,
      identifier: identifier,
      entitlements: entitlements,
    );
  }

  /// Signs each of [executables] ad-hoc with its entitlements, binding the
  /// bundle's `Info.plist`. Must run after `Info.plist` is final. Returns the
  /// signed executables' paths.
  ///
  /// A Mach-O the signer cannot lay out is reported and left with its linker
  /// signature: the build is still installable, only without the entitlements
  /// in the binary, which is the pre-#149 behaviour.
  Future<List<String>> embed(List<EntitledExecutable> executables) async {
    final signed = <String>[];
    for (final executable in executables) {
      final path = paths.join(executable.bundlePath, executable.executableName);
      final file = fileSystem.file(path);
      if (!file.existsSync()) continue;
      try {
        final bytes = await file.readAsBytes();
        final info = await fileSystem
            .file(paths.join(executable.bundlePath, 'Info.plist'))
            .readAsBytes();
        final output = AdHocSigner.sign(
          bytes,
          path: path,
          identifier: executable.identifier,
          entitlements: executable.entitlements,
          infoPlist: info,
        );
        await file.writeAsBytes(output, flush: true);
      } on AppleError catch (error) {
        log.logWarn(
          'Could not embed entitlements in $path: ${error.message}. '
          'Re-signers will not see them.',
        );
        continue;
      }
      log.logTrace(
        'embedded entitlements in ${paths.basename(executable.bundlePath)}: '
        '${executable.entitlements.keys.join(', ')}',
      );
      signed.add(path);
    }
    return signed;
  }

  Map<Object?, Object?>? _infoPlist(String bundlePath) {
    final file = fileSystem.file(paths.join(bundlePath, 'Info.plist'));
    if (!file.existsSync()) return null;
    try {
      final object = parsePlist(file.readAsBytesSync());
      return object is Map ? object : null;
    } on Object {
      return null;
    }
  }

  Map<String, Object?>? _readPlist(String path, String bundle) {
    final file = fileSystem.file(path);
    final Uint8List bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException catch (error) {
      log.logWarn(
        'Entitlements file "$path" of $bundle could not be read '
        '(${error.message}); the app is built without its entitlements.',
      );
      return null;
    }
    final Object? object;
    try {
      object = parsePlist(bytes);
    } on Object catch (error) {
      log.logWarn(
        'Entitlements file "$path" of $bundle is not a valid plist '
        '($error); the app is built without its entitlements.',
      );
      return null;
    }
    if (object is! Map) {
      log.logWarn('Entitlements file "$path" of $bundle is not a dictionary.');
      return null;
    }
    return object.cast<String, Object?>();
  }

  /// Parses a plist file's [bytes]: binary (`bplist00`) or XML, tolerating
  /// the UTF-8 byte-order mark Windows editors prepend (the XML reader
  /// rejects it). CRLF line endings are handled by the XML reader itself.
  @visibleForTesting
  static Object parsePlist(Uint8List bytes) {
    const binaryMagic = [0x62, 0x70, 0x6c, 0x69, 0x73, 0x74]; // bplist
    if (bytes.length >= binaryMagic.length &&
        Iterable<int>.generate(
          binaryMagic.length,
        ).every((i) => bytes[i] == binaryMagic[i])) {
      return PropertyListSerialization.propertyListWithData(
        ByteData.sublistView(bytes),
      );
    }
    var xml = utf8.decode(bytes);
    if (xml.startsWith('\uFEFF')) xml = xml.substring(1);
    return PropertyListSerialization.propertyListWithString(xml);
  }

  static final _variable = RegExp(r'\$\(([A-Za-z0-9_]+)(?::[^)]*)?\)');

  /// Expands `$(NAME)` from [variables], leaving unknown ones in place.
  static String _expand(String value, Map<String, String> variables) {
    var current = value;
    // Settings may reference settings; a few rounds cover real projects.
    for (var round = 0; round < 4 && current.contains(r'$('); round++) {
      current = current.replaceAllMapped(
        _variable,
        (match) => variables[match.group(1)!] ?? match.group(0)!,
      );
    }
    return current;
  }

  /// [value] with variables expanded, or null when something unresolvable
  /// remains. Arrays drop unresolvable elements; an array left empty that was
  /// not empty to begin with is dropped as a whole.
  @visibleForTesting
  static Object? expandValue(Object? value, Map<String, String> variables) =>
      _expandValue(value, variables);

  static Object? _expandValue(Object? value, Map<String, String> variables) {
    if (value is String) {
      final expanded = _expand(value, variables);
      return expanded.contains(r'$(') ? null : expanded;
    }
    if (value is List) {
      final kept = [
        for (final element in value)
          if (_expandValue(element, variables) case final Object kept) kept,
      ];
      return kept.isEmpty && value.isNotEmpty ? null : kept;
    }
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          if (_expandValue(entry.value, variables) case final Object kept)
            entry.key as String: kept,
      };
    }
    if (value is ByteData) return Uint8List.sublistView(value);
    return value;
  }
}
