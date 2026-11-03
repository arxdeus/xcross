import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/shared/signing/adhoc_signer.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/resource_manifest.dart';

/// A binary product SwiftPM built from source (a synthesized
/// `_xcross_<name>` target) instead of linking its static xcframework.
@internal
@immutable
final class StaticSourceFallback {
  const StaticSourceFallback({
    required this.name,
    required this.packageDir,
    this.version,
  });

  /// The product (and framework) name, e.g. `Sentry`.
  final String name;

  /// The package checkout holding the sources.
  final String packageDir;

  /// The resolved package version, or null.
  final String? version;
}

/// Embeds the static binary frameworks of SwiftPM packages the way Xcode
/// does.
///
/// Measured with Xcode 26.6 (`flutter build ipa` of a SwiftPM app): every
/// `.framework` binary target linked into the app is embedded in
/// `Runner.app/Frameworks`, also when its binary is a static archive. The
/// static code is linked into the app, so the embedded copy holds a stub
/// dylib (no defined symbols, linking only libSystem, the framework's
/// minimum OS in `LC_BUILD_VERSION`), the slice's `Info.plist` byte for
/// byte, and its resources (`PrivacyInfo.xcprivacy`, nested `.bundle`s).
/// Headers, modules and the archive are left out. App Store Connect reads
/// SDK privacy manifests from there (ITMS-91061). An xcframework of
/// libraries (`.a` plus headers) is not embedded.
///
/// SwiftPM copies every framework binary target a built product links, from
/// the slice of the build's platform, into its products directory, so those
/// copies are the input here.
@internal
final class StaticFrameworkStubs {
  const StaticFrameworkStubs({
    required this.fileSystem,
    required this.paths,
    required this.copier,
  });

  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final RecursiveDirectoryCopier copier;

  /// Entries of a slice framework Xcode does not embed.
  static const excluded = {
    'Headers',
    'PrivateHeaders',
    'Modules',
    '_CodeSignature',
    '.DS_Store',
  };

  /// `LC_BUILD_VERSION` platforms.
  static const platformIos = 2;
  static const platformIosSimulator = 7;

  /// The static `.framework`s SwiftPM copied next to [pluginLibraries] (its
  /// products directory), sorted by name.
  Future<List<String>> discover(Iterable<String> pluginLibraries) async {
    final found = <String>{};
    for (final directory in {...pluginLibraries.map(paths.dirname)}) {
      if (!fileSystem.directory(directory).existsSync()) continue;
      await for (final entity in fileSystem.directory(directory).list()) {
        if (entity is! Directory ||
            paths.extension(entity.path) != '.framework') {
          continue;
        }
        final binary = fileSystem.file(
          paths.join(entity.path, paths.basenameWithoutExtension(entity.path)),
        );
        if (!binary.existsSync()) continue;
        if (await isStaticArchiveFile(binary)) found.add(entity.path);
      }
    }
    return found.toList()
      ..sort((a, b) => paths.basename(a).compareTo(paths.basename(b)));
  }

  /// Discovers ([discover]) and embeds ([embed]) the static frameworks
  /// linked into [pluginLibraries]. [sdkVersion] is the version suffix of
  /// the SDK name, when it has one.
  Future<List<String>> embedLinked(
    Iterable<String> pluginLibraries,
    String frameworksDir, {
    required bool simulator,
    String? sdkVersion,
  }) async {
    final frameworks = await discover(pluginLibraries);
    final embedded = await embed(
      frameworks,
      frameworksDir,
      simulator: simulator,
      sdkVersion: sdkVersion,
    );
    for (final fallback in await discoverSourceFallbacks(pluginLibraries)) {
      final destination = await embedSourceFallback(
        fallback,
        frameworksDir,
        simulator: simulator,
        sdkVersion: sdkVersion,
      );
      if (destination != null) embedded.add(destination);
    }
    return embedded;
  }

  /// Prefix of the target xcross synthesizes when it builds a binary
  /// product from source (see `SwiftPmSourceFallback`).
  static const sourceFallbackPrefix = '_xcross_';

  /// Checkout directories never holding a product's own resources.
  static const nonProductDirectories = {
    'Tests',
    'Samples',
    'Sample',
    'Example',
    'Examples',
    'TestSamples',
    'Plans',
    'fastlane',
    'scripts',
    'docs',
    'develop-docs',
    '.git',
    '.build',
    '.xcross',
  };

  /// The binary products SwiftPM built from source instead of linking their
  /// static xcframework. The Windows host resolves manifests with
  /// `EXPERIMENTAL_SPM_BUILDS=1`, so sentry-cocoa's `Sentry` product becomes
  /// its source targets plus a synthesized `_xcross_Sentry`; no
  /// `Sentry.framework` reaches the products directory, yet Xcode (linking
  /// the static binary) embeds one carrying the privacy manifest. Each has a
  /// `_xcross_<Product>.build` next to [pluginLibraries] and a compatibility
  /// directory `<scratch>/checkouts/<package>/.xcross/_xcross_<Product>`.
  Future<List<StaticSourceFallback>> discoverSourceFallbacks(
    Iterable<String> pluginLibraries,
  ) async {
    final found = <String, StaticSourceFallback>{};
    for (final directory in {...pluginLibraries.map(paths.dirname)}) {
      if (!fileSystem.directory(directory).existsSync()) continue;
      final scratch = paths.dirname(paths.dirname(directory));
      final checkouts = fileSystem.directory(paths.join(scratch, 'checkouts'));
      if (!checkouts.existsSync()) continue;
      final packages = [
        for (final entity in checkouts.listSync(followLinks: false))
          if (entity is Directory) entity.path,
      ]..sort();
      await for (final entity in fileSystem.directory(directory).list()) {
        final base = paths.basename(entity.path);
        if (entity is! Directory ||
            !base.startsWith(sourceFallbackPrefix) ||
            paths.extension(base) != '.build') {
          continue;
        }
        final synthetic = paths.basenameWithoutExtension(base);
        final name = synthetic.substring(sourceFallbackPrefix.length);
        if (name.isEmpty || found.containsKey(name)) continue;
        for (final package in packages) {
          final marker = paths.join(package, '.xcross', synthetic);
          if (!fileSystem.directory(marker).existsSync()) continue;
          found[name] = StaticSourceFallback(
            name: name,
            packageDir: package,
            version: checkoutVersion(scratch, paths.basename(package)),
          );
          break;
        }
      }
    }
    return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Embeds a stub framework for [fallback] into [frameworksDir], as Xcode
  /// embeds the static binary it replaces: an `Info.plist`, the package's
  /// privacy manifest, and a stub binary. Returns null when the name is
  /// already embedded or the package ships no single privacy manifest.
  Future<String?> embedSourceFallback(
    StaticSourceFallback fallback,
    String frameworksDir, {
    required bool simulator,
    String? sdkVersion,
  }) async {
    final name = fallback.name;
    final destination = paths.join(frameworksDir, '$name.framework');
    if (fileSystem.directory(destination).existsSync()) return null;
    final privacy = privacyManifestOf(fallback.packageDir);
    if (privacy == null) return null;
    final manifest = fileSystem.file(
      paths.join(fallback.packageDir, 'Package.swift'),
    );
    final minimum = manifest.existsSync()
        ? swiftPmPackageMinimumOsVersion(await manifest.readAsString())
        : swiftPmOldestIosVersion;
    final version = fallback.version ?? '1.0';
    final identity = paths.basename(fallback.packageDir).toLowerCase();
    final info = <String, Object>{
      'CFBundleDevelopmentRegion': 'en',
      'CFBundleExecutable': name,
      'CFBundleIdentifier': '$identity.$name'.replaceAll(
        RegExp('[^A-Za-z0-9.-]'),
        '-',
      ),
      'CFBundleInfoDictionaryVersion': '6.0',
      'CFBundleName': name,
      'CFBundlePackageType': 'FMWK',
      'CFBundleShortVersionString': version,
      'CFBundleSupportedPlatforms': [
        if (simulator) 'iPhoneSimulator' else 'iPhoneOS',
      ],
      'CFBundleVersion': version,
      'MinimumOSVersion': minimum,
    };
    final staging = paths.join(
      paths.dirname(frameworksDir),
      '.xcross-stub-$name',
    );
    final source = paths.join(staging, '$name.framework');
    await fileSystem.directory(source).create(recursive: true);
    try {
      await fileSystem
          .file(paths.join(source, 'Info.plist'))
          .writeAsString(
            PropertyListSerialization.stringWithPropertyList(info),
          );
      await fileSystem
          .file(privacy)
          .copy(paths.join(source, 'PrivacyInfo.xcprivacy'));
      final embedded = await embed(
        [source],
        frameworksDir,
        simulator: simulator,
        sdkVersion: sdkVersion,
      );
      return embedded.singleOrNull;
    } finally {
      await fileSystem.directory(staging).delete(recursive: true);
    }
  }

  /// The one `PrivacyInfo.xcprivacy` of [packageDir] outside tests, samples
  /// and tooling, or null when there is none or more than one.
  String? privacyManifestOf(String packageDir) {
    final found = <String>[];
    void walk(String directory) {
      for (final entity
          in fileSystem.directory(directory).listSync(followLinks: false)) {
        final base = paths.basename(entity.path);
        if (entity is Directory) {
          if (nonProductDirectories.contains(base) ||
              paths.extension(base) == '.xcodeproj' ||
              paths.extension(base) == '.xcworkspace') {
            continue;
          }
          walk(entity.path);
        } else if (entity is File && base == 'PrivacyInfo.xcprivacy') {
          found.add(entity.path);
        }
      }
    }

    walk(packageDir);
    return found.length == 1 ? found.single : null;
  }

  /// The resolved version of checkout [subpath] in
  /// `<scratch>/workspace-state.json`, or null.
  String? checkoutVersion(String scratch, String subpath) {
    final state = fileSystem.file(paths.join(scratch, 'workspace-state.json'));
    if (!state.existsSync()) return null;
    try {
      final decoded = jsonDecode(state.readAsStringSync());
      final object = decoded is Map ? decoded['object'] : null;
      final dependencies = object is Map ? object['dependencies'] : null;
      if (dependencies is! List) return null;
      for (final dependency in dependencies) {
        if (dependency is! Map || dependency['subpath'] != subpath) continue;
        final dependencyState = dependency['state'];
        final checkout = dependencyState is Map
            ? dependencyState['checkoutState']
            : null;
        final version = checkout is Map ? checkout['version'] : null;
        return version is String && version.isNotEmpty ? version : null;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// The trailing version of an SDK name (`26.5` of `iphoneos26.5`), or null.
  static String? sdkVersionOf(String sdkName) =>
      RegExp(r'(\d+(?:\.\d+)*)$').firstMatch(sdkName)?.group(1);

  /// Whether [file] is a static archive, thin or as a slice of a fat file,
  /// reading only the headers (archives run to hundreds of megabytes).
  static Future<bool> isStaticArchiveFile(File file) async {
    final handle = await file.open();
    try {
      final head = await handle.read(4096);
      if (_startsWithArchive(head, 0)) return true;
      if (head.length < 8) return false;
      final data = ByteData.sublistView(head);
      final magic = data.getUint32(0);
      if (magic != _fatMagic && magic != _fatMagic64) return false;
      final stride = magic == _fatMagic64 ? 32 : 20;
      final count = data.getUint32(4);
      for (var index = 0; index < count; index++) {
        final entry = 8 + index * stride;
        if (entry + stride > head.length) return false;
        final offset = magic == _fatMagic64
            ? data.getUint64(entry + 8)
            : data.getUint32(entry + 8);
        await handle.setPosition(offset);
        if (_startsWithArchive(await handle.read(8), 0)) return true;
      }
      return false;
    } finally {
      await handle.close();
    }
  }

  static const _fatMagic = 0xcafebabe;
  static const _fatMagic64 = 0xcafebabf;

  /// Embeds a stub framework for each of [frameworks] (static `.framework`
  /// directories) into [frameworksDir], skipping names already embedded.
  /// [sdkVersion] (e.g. `26.5`) goes into `LC_BUILD_VERSION.sdk`.
  Future<List<String>> embed(
    Iterable<String> frameworks,
    String frameworksDir, {
    required bool simulator,
    String? sdkVersion,
  }) async {
    final embedded = <String>[];
    for (final framework in frameworks) {
      final name = paths.basenameWithoutExtension(framework);
      final destination = paths.join(frameworksDir, '$name.framework');
      if (fileSystem.directory(destination).existsSync()) continue;
      await fileSystem.directory(destination).create(recursive: true);
      await for (final entity in fileSystem.directory(framework).list()) {
        final entry = paths.basename(entity.path);
        if (excluded.contains(entry) || entry == name) continue;
        final target = paths.join(destination, entry);
        if (entity is Directory) {
          await copier.copy(entity.path, target);
        } else if (entity is File) {
          await entity.copy(fileSystem.file(target).path);
        }
      }
      final infoPlist = fileSystem.file(paths.join(destination, 'Info.plist'));
      final info = infoPlist.existsSync()
          ? await infoPlist.readAsBytes()
          : null;
      final minimum =
          (info == null ? null : minimumOsVersion(info)) ?? sdkVersion ?? '0';
      var stub = stubDylib(
        installName: '@rpath/$name.framework/$name',
        platform: simulator ? platformIosSimulator : platformIos,
        minimumOs: minimum,
        sdk: sdkVersion ?? minimum,
      );
      try {
        stub = AdHocSigner.sign(
          stub,
          path: paths.join(destination, name),
          identifier: name,
          entitlements: const {},
          infoPlist: info,
        );
      } on AppleError {
        // Left unsigned: the bundle signer signs every framework anyway.
      }
      final binary = paths.join(destination, name);
      await fileSystem.file(binary).writeAsBytes(stub, flush: true);
      fileSystem.makeExecutable(binary);
      embedded.add(destination);
    }
    return embedded;
  }

  static bool _startsWithArchive(Uint8List bytes, int offset) {
    const magic = '!<arch>\n';
    if (offset + magic.length > bytes.length) return false;
    for (var index = 0; index < magic.length; index++) {
      if (bytes[offset + index] != magic.codeUnitAt(index)) return false;
    }
    return true;
  }

  /// `MinimumOSVersion` of a framework `Info.plist`, or null.
  static String? minimumOsVersion(Uint8List info) {
    try {
      final Object plist;
      if (info.length >= 6 && ascii.decode(info.sublist(0, 6)) == 'bplist') {
        plist = PropertyListSerialization.propertyListWithData(
          ByteData.sublistView(info),
        );
      } else {
        var xml = utf8.decode(info);
        if (xml.startsWith('\uFEFF')) xml = xml.substring(1);
        plist = PropertyListSerialization.propertyListWithString(xml);
      }
      final value = plist is Map ? plist['MinimumOSVersion'] : null;
      return value is String && value.isNotEmpty ? value : null;
    } on Object {
      return null;
    }
  }

  /// Encodes `major.minor.patch` as Mach-O's `xxxx.yy.zz` nibbles.
  static int encodeVersion(String version) {
    final parts = version.split('.').map((part) => int.tryParse(part) ?? 0);
    final [major, minor, patch] = [...parts, 0, 0, 0].take(3).toList();
    return (major.clamp(0, 0xffff) << 16) |
        (minor.clamp(0, 0xff) << 8) |
        patch.clamp(0, 0xff);
  }

  static const _pageSize = 0x4000;

  /// A thin arm64 `MH_DYLIB` with no code and no symbols, linking only
  /// libSystem: what `ld64 -dylib` makes of no objects. Leaves room for the
  /// `LC_CODE_SIGNATURE` a signer adds.
  static Uint8List stubDylib({
    required String installName,
    required int platform,
    required String minimumOs,
    required String sdk,
  }) {
    const libSystem = '/usr/lib/libSystem.B.dylib';
    final commands = BytesBuilder();
    var count = 0;
    void command(int type, List<int> body) {
      final size = 8 + body.length;
      final padded = (size + 7) & ~7;
      final data = ByteData(padded)
        ..setUint32(0, type, Endian.little)
        ..setUint32(4, padded, Endian.little);
      final bytes = data.buffer.asUint8List()..setRange(8, size, body);
      commands.add(bytes);
      count++;
    }

    Uint8List words(List<int> values, {int width = 4}) {
      final data = ByteData(values.length * width);
      for (var index = 0; index < values.length; index++) {
        if (width == 8) {
          data.setUint64(index * 8, values[index], Endian.little);
        } else {
          data.setUint32(index * 4, values[index], Endian.little);
        }
      }
      return data.buffer.asUint8List();
    }

    Uint8List segment(
      String name,
      int vmAddress,
      int vmSize,
      int fileOffset,
      int fileSize,
      int protection, {
      bool emptyText = false,
    }) {
      final body = BytesBuilder()
        ..add(ascii.encode(name.padRight(16, '\u0000')))
        ..add(words([vmAddress, vmSize, fileOffset, fileSize], width: 8))
        ..add(words([protection, protection, if (emptyText) 1 else 0, 0]));
      if (emptyText) {
        // An empty `__text` at the end of the page, as ld64 leaves it
        // (signers locate the code through it).
        body
          ..add(ascii.encode('__text'.padRight(16, '\u0000')))
          ..add(ascii.encode(name.padRight(16, '\u0000')))
          ..add(words([vmAddress + fileSize, 0], width: 8))
          // S_REGULAR | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS
          ..add(words([fileOffset + fileSize, 2, 0, 0, 0x80000400, 0, 0, 0]));
      }
      return body.toBytes();
    }

    Uint8List dylib(String path, int current, int compatibility) {
      final body = BytesBuilder()
        ..add(words([24, 2, current, compatibility]))
        ..add(utf8.encode(path))
        ..addByte(0);
      return body.toBytes();
    }

    // __LINKEDIT holds only an empty string table (one space and padding).
    const linkeditSize = 8;
    const vmProtRead = 1;
    const vmProtReadExecute = 5;
    command(
      0x19,
      segment(
        '__TEXT',
        0,
        _pageSize,
        0,
        _pageSize,
        vmProtReadExecute,
        emptyText: true,
      ),
    );
    command(
      0x19,
      segment(
        '__LINKEDIT',
        _pageSize,
        _pageSize,
        _pageSize,
        linkeditSize,
        vmProtRead,
      ),
    );
    command(0x22 | 0x80000000, words(List.filled(10, 0))); // LC_DYLD_INFO_ONLY
    command(0x2, words([_pageSize, 0, _pageSize, linkeditSize])); // LC_SYMTAB
    command(0xb, words(List.filled(18, 0))); // LC_DYSYMTAB
    command(0xd, dylib(installName, 0x10000, 0x10000)); // LC_ID_DYLIB
    final digest = sha256.convert(utf8.encode('$installName\u0000$platform'));
    final uuid = Uint8List.fromList(digest.bytes.sublist(0, 16));
    uuid[6] = (uuid[6] & 0x0f) | 0x30;
    uuid[8] = (uuid[8] & 0x3f) | 0x80;
    command(0x1b, uuid); // LC_UUID
    command(
      0x32, // LC_BUILD_VERSION
      words([platform, encodeVersion(minimumOs), encodeVersion(sdk), 0]),
    );
    command(0xc, dylib(libSystem, 0x054c0000, 0x10000)); // LC_LOAD_DYLIB
    final loadCommands = commands.toBytes();
    final header = ByteData(32)
      ..setUint32(0, 0xfeedfacf, Endian.little)
      ..setUint32(4, 0x0100000c, Endian.little)
      ..setUint32(8, 0, Endian.little)
      ..setUint32(12, 0x6, Endian.little) // MH_DYLIB
      ..setUint32(16, count, Endian.little)
      ..setUint32(20, loadCommands.length, Endian.little)
      // MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_NO_REEXPORTED_DYLIBS
      ..setUint32(24, 0x1 | 0x4 | 0x80 | 0x100000, Endian.little);
    final file = Uint8List(_pageSize + linkeditSize)
      ..setRange(0, 32, header.buffer.asUint8List())
      ..setRange(32, 32 + loadCommands.length, loadCommands);
    file[_pageSize] = 0x20;
    return file;
  }
}
