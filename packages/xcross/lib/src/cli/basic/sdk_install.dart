import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/basic/internal/hard_link_payloads.dart';
import 'package:xcross/src/cli/basic/internal/swift_sibling_clang.dart';
import 'package:xcross/src/errors.dart';

/// The iOS subset required by Swift's Linux cross-SDK protocol.
const sdkIncludedRoots = <String>[
  'Developer/Platforms/iPhoneOS.platform/Developer/SDKs',
  'Developer/Platforms/iPhoneOS.platform/Developer/Library/Frameworks',
  'Developer/Platforms/iPhoneOS.platform/Developer/Library/PrivateFrameworks',
  'Developer/Platforms/iPhoneOS.platform/Developer/usr/lib',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/include',
];

const _platformDeveloper = 'Developer/Platforms/iPhoneOS.platform/Developer';
const _toolchain = 'Developer/Toolchains/XcodeDefault.xctoolchain';
const _swiftResources = '$_toolchain/usr/lib/swift';
const _swiftStaticResources = '$_toolchain/usr/lib/swift_static';

/// POSIX `st_mode` bits carried by every cpio entry.
const _fileTypeMask = 0xF000;
const _directoryType = 0x4000;
const _regularFileType = 0x8000;
const _symbolicLinkType = 0xA000;
const _anyExecuteBit = 0x049; // u+x | g+x | o+x

const _json = JsonEncoder.withIndent('  ');

/// Records which host Swift toolchain the installed bundle was patched
/// against. The bundle's `swift/clang/include` headers and its Swift
/// resources are only valid for that one toolchain's module ABI: building
/// with a different `swift` fails with "this SDK is not supported by the
/// compiler ... Please select a toolchain which matches the SDK."
const hostToolchainStampName = 'xcross-host-toolchain.json';

/// Windows reports "a DLL this executable needs is missing" as a bare exit
/// code, with no output on either stream.
const _statusDllNotFound = 0xC0000135;

/// The compiler-mismatch diagnostic Swift emits when the bundle was patched
/// against a different toolchain than the one now building.
const swiftSdkMismatchMarker = 'this SDK is not supported by the compiler';

/// Helpers for extracting and wiring the Darwin Swift SDK bundle.
abstract final class SdkInstall {
  /// Destination-relative path for an included cpio entry, or null when the
  /// entry is outside [sdkIncludedRoots].
  static String? sdkRelativePath(String name) {
    final archiveName = name.replaceAll(r'\', '/');
    for (final root in sdkIncludedRoots) {
      if (archiveName == root || archiveName.startsWith('$root/')) {
        return archiveName;
      }
      // Otherwise the root may sit under a prefix such as `Xcode.app/
      // Contents/`; take the first occurrence that ends on a path boundary.
      final anchor = '/$root';
      var index = archiveName.indexOf(anchor);
      while (index >= 0) {
        final end = index + anchor.length;
        if (end == archiveName.length || archiveName[end] == '/') {
          return archiveName.substring(index + 1);
        }
        index = archiveName.indexOf(anchor, index + 1);
      }
    }
    return null;
  }

  static Future<int> writeSdkEntries(
    Stream<CpioEntry> entries,
    String destDir, {
    bool? materializeLinks,
    void Function(int count)? onProgress,
    void Function(int done, int total)? onLinkProgress,
  }) async {
    final root = p.normalize(p.absolute(destDir));
    await Directory(ioPath(root)).create(recursive: true);
    final links = <String, String>{};
    final hardLinks = HardLinkPayloads();
    var written = 0;

    await for (final entry in entries) {
      // Runs before the inclusion filter: an excluded entry may still carry
      // the only copy of a payload an included hard link shares.
      final fileType = entry.mode & _fileTypeMask;
      final data = hardLinks.payloadFor(
        entry,
        isRegular: fileType == _regularFileType || fileType == 0,
      );
      final destPath = _destinationPath(root, entry);
      if (destPath == null) continue;

      switch (entry.mode & _fileTypeMask) {
        case _directoryType:
          await Directory(ioPath(destPath)).create(recursive: true);
        case _symbolicLinkType:
          await _createParentDirectory(destPath);
          links[destPath] = utf8.decode(entry.data);
        case _regularFileType || 0:
          await _createParentDirectory(destPath);
          await File(ioPath(destPath)).writeAsBytes(data);
          if (entry.mode & _anyExecuteBit != 0) {
            ProcessRunner.makeExecutable(destPath);
          }
        default:
          continue;
      }

      written++;
      onProgress?.call(written);
    }

    if (materializeLinks ?? Platform.isWindows) {
      await _materializeSdkLinks(root, links, onProgress: onLinkProgress);
    } else {
      var linked = 0;
      for (final link in links.entries) {
        _resolvedSdkLinkTarget(root, link.key, link.value);
        await Link(link.key).create(link.value, recursive: true);
        onLinkProgress?.call(++linked, links.length);
      }
    }
    return written;
  }

  /// Absolute destination for an included cpio entry, or null when the entry
  /// is outside [sdkIncludedRoots].
  ///
  /// Rejects `..` segments and anything resolving outside [root] so a hostile
  /// archive cannot write over arbitrary host files.
  static String? _destinationPath(String root, CpioEntry entry) {
    final archivePath = sdkRelativePath(entry.name);
    if (archivePath == null) return null;
    if (archivePath.split('/').contains('..')) {
      throw XcrossError('Unsafe SDK archive path: ${entry.name}');
    }
    final relative = p.normalize(archivePath.replaceAll('/', p.separator));
    final destPath = p.normalize(p.join(root, relative));
    if (p.isAbsolute(relative) || !p.isWithin(root, destPath)) {
      throw XcrossError('Unsafe SDK archive path: ${entry.name}');
    }
    return destPath;
  }

  /// Windows has no usable unprivileged symlink, so every link becomes a copy
  /// of its target. Targets may themselves be links, so this loops until no
  /// link makes progress; a directory waits until nothing else links inside it.
  static Future<void> _materializeSdkLinks(
    String root,
    Map<String, String> links, {
    void Function(int done, int total)? onProgress,
  }) async {
    final pending = Map<String, String>.from(links);
    while (pending.isNotEmpty) {
      var progressed = false;
      for (final link in pending.entries.toList()) {
        final target = _resolvedSdkLinkTarget(root, link.key, link.value);
        final type = FileSystemEntity.typeSync(ioPath(target));
        if (type == FileSystemEntityType.notFound) continue;
        if (type == FileSystemEntityType.directory &&
            pending.keys.any(
              (other) => other != link.key && p.isWithin(target, other),
            )) {
          continue;
        }

        switch (type) {
          case FileSystemEntityType.directory:
            await _copySdkDirectory(target, link.key);
          case FileSystemEntityType.file:
            await File(ioPath(target)).copy(ioPath(link.key));
          default:
            throw XcrossError('Unsupported SDK symlink target: ${link.value}');
        }
        pending.remove(link.key);
        progressed = true;
        onProgress?.call(links.length - pending.length, links.length);
      }
      if (!progressed) {
        throw XcrossError(
          'Could not resolve SDK symlinks: ${pending.values.join(', ')}',
        );
      }
    }
  }

  /// Resolves a link target and rejects anything reaching outside the bundle.
  static String _resolvedSdkLinkTarget(
    String root,
    String link,
    String rawTarget,
  ) {
    final targetPath = rawTarget.replaceAll('/', p.separator);
    if (p.isAbsolute(targetPath)) {
      throw XcrossError('SDK symlink target is absolute: $rawTarget');
    }
    final target = p.normalize(p.join(p.dirname(link), targetPath));
    if (!p.isWithin(root, target)) {
      throw XcrossError('SDK symlink escapes the SDK: $rawTarget');
    }
    return target;
  }

  static Future<void> _copySdkDirectory(
    String source,
    String destination,
  ) async {
    await Directory(ioPath(destination)).create(recursive: true);
    await for (final entity in Directory(ioPath(source)).list()) {
      final target = p.join(destination, p.basename(entity.path));
      switch (FileSystemEntity.typeSync(entity.path)) {
        case FileSystemEntityType.directory:
          await _copySdkDirectory(entity.path, target);
        case FileSystemEntityType.file:
          await File(entity.path).copy(ioPath(target));
        default:
          continue;
      }
    }
  }

  static Future<Directory> _createParentDirectory(String path) =>
      Directory(ioPath(p.dirname(path))).create(recursive: true);

  /// Win32 directory enumeration appends `\\*`, which still hits `MAX_PATH`
  /// unless the absolute path uses the extended-length prefix.
  static String ioPath(String path) {
    if (!Platform.isWindows) return path;
    final absolute = p.absolute(path);
    if (absolute.startsWith(r'\\?\')) return absolute;
    if (absolute.startsWith(r'\\')) {
      return '\\\\?\\UNC\\${absolute.substring(2)}';
    }
    return '\\\\?\\$absolute';
  }

  /// Copy Swift's canonical iPhoneOS layout into its legacy Runtime location.
  static Future<void> materializeSwiftCompatibilityResources(
    String artifactRoot,
  ) async {
    final source = File(
      ioPath(
        p.join(artifactRoot, _swiftResources, 'iphoneos', 'layouts-arm64.yaml'),
      ),
    );
    if (!source.existsSync() || source.lengthSync() == 0) {
      throw XcrossError(
        'Missing or empty canonical Swift iPhoneOS layout: ${source.path}',
      );
    }
    final destination = ioPath(
      p.join(
        artifactRoot,
        'Developer',
        'Runtimes',
        'XcodeDefault.xctoolchain',
        'usr',
        'bin',
        'layouts-arm64.yaml',
      ),
    );
    await Directory(p.dirname(destination)).create(recursive: true);
    await source.copy(destination);
  }

  /// Write the Swift artifact-bundle metadata after extraction.
  static Future<void> writeSwiftSdkBundleMetadata(String artifactRoot) async {
    final sdkRoot = DarwinSdk(artifactRoot).iPhoneOSSdk();
    if (!RegExp('[0-9]').hasMatch(p.basename(sdkRoot))) {
      throw XcrossError(
        'The extracted Xcode archive did not contain a versioned iPhoneOS SDK.',
      );
    }
    // Bundle metadata is always forward-slashed, including on Windows.
    final relativeSdkRoot = p
        .relative(sdkRoot, from: artifactRoot)
        .replaceAll(r'\', '/');
    final toolchainCxx = p.join(artifactRoot, _toolchain, 'usr/include/c++/v1');
    final sdkCxx = p.join(sdkRoot, 'usr/include/c++/v1');
    final cxxInclude = Directory(toolchainCxx).existsSync()
        ? '$_toolchain/usr/include/c++/v1'
        : p.relative(sdkCxx, from: artifactRoot).replaceAll(r'\', '/');

    await _writeJson(p.join(artifactRoot, 'swift-sdk.json'), {
      'schemaVersion': '4.0',
      'targetTriples': {
        'arm64-apple-ios': {
          'sdkRootPath': relativeSdkRoot,
          'swiftResourcesPath': _swiftResources,
          'swiftStaticResourcesPath': _swiftStaticResources,
          'includeSearchPaths': ['$_platformDeveloper/usr/lib', cxxInclude],
          'librarySearchPaths': ['$_platformDeveloper/usr/lib'],
          'toolsetPaths': ['toolset.json'],
        },
      },
    });
    await _writeJson(p.join(artifactRoot, 'toolset.json'), const {
      'schemaVersion': '1.0',
      'swiftCompiler': {
        'extraCLIOptions': [
          '-Xfrontend',
          '-enable-cross-import-overlays',
          '-use-ld=lld',
        ],
      },
    });
    await _writeJson(p.join(artifactRoot, 'info.json'), const {
      'schemaVersion': '1.0',
      'artifacts': {
        'xcross-darwin': {
          'type': 'swiftSDK',
          'version': '1.0.0',
          'variants': [
            {
              'path': '.',
              'supportedTriples': [
                'x86_64-unknown-linux-gnu',
                'aarch64-unknown-linux-gnu',
                'x86_64-unknown-windows-msvc',
                'aarch64-unknown-windows-msvc',
              ],
            },
          ],
        },
      },
    });
  }

  static Future<void> _writeJson(String path, Map<String, Object?> value) =>
      File(path).writeAsString('${_json.convert(value)}\n');

  /// Replace Xcode's clang builtin headers with headers matching host Swift.
  static Future<void> replaceClangBuiltinHeaders(
    String artifactRoot, {
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) async {
    final sibling = await _swiftSiblingClang(
      locateTool ?? ProcessRunner.locateTool,
    );
    final source = await _clangBuiltinHeaderDir(
      sibling.clang,
      sibling.swift,
      runProcess ?? ProcessRunner.run,
    );
    final destination = p.join(
      artifactRoot,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
      'clang',
      'include',
    );
    await _deleteAnyEntity(destination);
    await _copySdkDirectory(source, destination);
    await _writeHostToolchainStamp(
      artifactRoot,
      sibling,
      runProcess ?? ProcessRunner.run,
    );
  }

  /// Identity of the host Swift toolchain the bundle is patched against:
  /// its resolved install path plus the version string it reports. The path
  /// alone is not enough — swiftly and mise reuse one directory across
  /// toolchain upgrades — and the version alone is not enough either, since
  /// two builds of the same version can differ in module ABI (the reported
  /// "swiftlang-…" build differs between a vendor and a swift.org build).
  @visibleForTesting
  static Future<Map<String, String>> hostToolchainIdentity({
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) async {
    final sibling = await _swiftSiblingClang(
      locateTool ?? ProcessRunner.locateTool,
    );
    return _identity(sibling, runProcess ?? ProcessRunner.run);
  }

  static Future<Map<String, String>> _identity(
    SwiftSiblingClang sibling,
    Future<CapturedProcess> Function(String, List<String>) run,
  ) async {
    return {
      'swift': sibling.swift,
      'version': await _toolchainVersion(sibling, run),
    };
  }

  /// The version string identifying this toolchain's Swift module ABI.
  ///
  /// `swift` itself is not always askable: mise and swiftly resolve it to
  /// `swift-driver`, which refuses to run under that name ("invalid driver
  /// name: swift-driver") and so reports no version at all. `swift-frontend`
  /// is the binary that actually reads and writes `.swiftinterface`, so it is
  /// both the more accurate answer and the one that always responds; the
  /// sibling `clang` is the last resort. An empty result is not fatal: the
  /// comparison falls back to the recorded toolchain path.
  static Future<String> _toolchainVersion(
    SwiftSiblingClang sibling,
    Future<CapturedProcess> Function(String, List<String>) run,
  ) async {
    final bin = p.dirname(sibling.swift);
    final candidates = <String>[
      p.join(bin, ProcessRunner.hostExecutableName('swift-frontend')),
      sibling.swift,
      sibling.clang,
    ];
    for (final candidate in candidates) {
      if (candidate != sibling.swift && !File(candidate).existsSync()) continue;
      try {
        final printed = await run(candidate, const ['--version']);
        if (printed.exitCode != 0) continue;
        final output = printed.stdout.trim().isEmpty
            ? printed.stderr.trim()
            : printed.stdout.trim();
        // `swift --version` prints the version line plus a `Target:` line.
        // Only the first line names the compiler build that fixes the module
        // ABI, and keeping just it makes stamps written by different tools
        // (and different host triples) comparable.
        final version = _firstLine(output);
        if (version.isNotEmpty) return version;
      } on Object catch (error) {
        Log.logTrace('$candidate --version failed while stamping SDK: $error');
      }
    }
    return '';
  }

  static Future<void> _writeHostToolchainStamp(
    String artifactRoot,
    SwiftSiblingClang sibling,
    Future<CapturedProcess> Function(String, List<String>) run,
  ) async {
    final identity = await _identity(sibling, run);
    await _writeJson(p.join(artifactRoot, hostToolchainStampName), identity);
  }

  /// The toolchain identity recorded when the bundle was installed, or null
  /// when the bundle predates stamping or the stamp is unreadable.
  static Map<String, String>? readHostToolchainStamp(String artifactRoot) {
    final file = File(p.join(artifactRoot, hostToolchainStampName));
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      return {
        for (final entry in decoded.entries)
          '${entry.key}': '${entry.value ?? ''}',
      };
    } on Object catch (error) {
      Log.logTrace('Unreadable host toolchain stamp at ${file.path}: $error');
      return null;
    }
  }

  /// Human-readable reason the installed bundle does not match the Swift
  /// toolchain now on PATH, or null when it matches or cannot be judged.
  ///
  /// An unstamped bundle is never reported as mismatched: it was installed
  /// by an older xcross and may well be fine, and guessing wrong would send
  /// users through a multi-gigabyte reinstall for nothing.
  static Future<String?> hostToolchainMismatch(
    String artifactRoot, {
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) async {
    final recorded = readHostToolchainStamp(artifactRoot);
    if (recorded == null) return null;
    final Map<String, String> current;
    try {
      current = await hostToolchainIdentity(
        locateTool: locateTool,
        runProcess: runProcess,
      );
    } on Object catch (error) {
      Log.logTrace('Could not identify the host Swift toolchain: $error');
      return null;
    }
    final recordedVersion = recorded['version'] ?? '';
    final currentVersion = current['version'] ?? '';
    // An empty version on either side means the comparison never happened,
    // so fall back to the path, which is always recorded.
    if (recordedVersion.isNotEmpty && currentVersion.isNotEmpty) {
      if (recordedVersion == currentVersion) return null;
      return 'The Darwin SDK was installed against Swift '
          '"${_firstLine(recordedVersion)}" (${recorded['swift']}), but the '
          '`swift` now on PATH is "${_firstLine(currentVersion)}" '
          '(${current['swift']}).';
    }
    if (recorded['swift'] == current['swift']) return null;
    return 'The Darwin SDK was installed against the Swift toolchain at '
        '"${recorded['swift']}", but `swift` now resolves to '
        '"${current['swift']}".';
  }

  /// What to tell a user whose build hit either the recorded mismatch or
  /// Swift's own compiler-mismatch diagnostic.
  static String mismatchGuidance(String? detail) => [
    if (detail != null) detail,
    _mismatchCause,
    _mismatchRemedy,
    '    xcross sdk install <path-to-Xcode.xip>',
  ].join('\n');

  static const _mismatchCause =
      'The Darwin SDK bundle carries Swift module interfaces that only the '
      'toolchain it was installed with can compile, so switching Swift '
      'versions (swiftly, mise, or a distro upgrade) invalidates it.';

  static const _mismatchRemedy =
      'Either select the Swift toolchain the SDK was installed with, or '
      'reinstall the SDK against the current one:';

  static String _firstLine(String value) => value.split('\n').first.trim();

  /// The clang shipped beside the selected `swift`, which is the one whose
  /// builtin headers match that Swift's module ABI.
  static Future<SwiftSiblingClang> _swiftSiblingClang(
    Future<String> Function(String name) locate,
  ) async {
    final String swift;
    try {
      swift = await locate('swift');
    } on Object {
      throw XcrossError(
        'Could not locate the selected Swift executable `swift` on PATH.',
      );
    }

    final String resolvedSwift;
    try {
      resolvedSwift = await File(swift).resolveSymbolicLinks();
    } on Object {
      throw XcrossError(
        'Could not resolve selected Swift executable "$swift".',
      );
    }

    final clang = p.join(
      p.dirname(resolvedSwift),
      ProcessRunner.hostExecutableName('clang'),
    );
    if (!File(clang).existsSync()) {
      throw XcrossError(
        'Selected Swift executable "$resolvedSwift" has no sibling clang at '
        '"$clang".',
      );
    }
    return SwiftSiblingClang(clang: clang, swift: resolvedSwift);
  }

  static Future<String> _clangBuiltinHeaderDir(
    String clang,
    String resolvedSwift,
    Future<CapturedProcess> Function(String, List<String>) run,
  ) async {
    CapturedProcess? printed;
    Object? failure;
    try {
      printed = await run(clang, const ['-print-resource-dir']);
    } on Object catch (error) {
      failure = error;
    }

    if (printed != null && printed.exitCode == 0) {
      final resourceDir = printed.stdout.trim();
      if (resourceDir.isNotEmpty) {
        final source = p.join(resourceDir, 'include');
        if (Directory(source).existsSync()) return source;
      }
    }

    // Asking clang is only the fast path: a toolchain whose binaries cannot
    // even start still ships its builtin headers at a fixed spot, and nothing
    // about installing the SDK actually needs to run the compiler.
    final shipped = _shippedClangHeaderDir(clang);
    if (shipped != null) {
      Log.logWarn(
        'clang -print-resource-dir failed; falling back to the headers '
        'shipped at "$shipped".${_clangFailureDetail(printed, failure)}',
      );
      return shipped;
    }

    throw XcrossError(
      'Could not locate clang builtin headers using sibling clang "$clang" '
      'selected for Swift "$resolvedSwift".'
      '${_clangFailureDetail(printed, failure)}',
    );
  }

  /// The builtin headers a toolchain ships, located without running clang:
  /// `usr/lib/clang/<version>/include`, or the copy Swift keeps beside its own
  /// resources at `usr/lib/swift/clang/include`.
  static String? _shippedClangHeaderDir(String clang) {
    final lib = p.join(p.dirname(p.dirname(clang)), 'lib');
    final versions = Directory(p.join(lib, 'clang'));
    final candidates = <String>[];
    if (versions.existsSync()) {
      final byVersion =
          versions
              .listSync()
              .whereType<Directory>()
              .map((entity) => p.basename(entity.path))
              .toList()
            ..sort(_compareClangVersions);
      candidates.addAll(
        byVersion.map((version) => p.join(lib, 'clang', version, 'include')),
      );
    }
    candidates.add(p.join(lib, 'swift', 'clang', 'include'));
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Newest resource directory first, over the dotted numeric versions clang
  /// uses for its resource directories (`21` sorts above `19.1.7`).
  static int _compareClangVersions(String a, String b) {
    final left = _versionSegments(a);
    final right = _versionSegments(b);
    for (var i = 0; i < left.length && i < right.length; i++) {
      final order = right[i].compareTo(left[i]);
      if (order != 0) return order;
    }
    return right.length.compareTo(left.length);
  }

  static List<int> _versionSegments(String version) => version
      .split('.')
      .map((segment) => int.tryParse(segment) ?? -1)
      .toList(growable: false);

  /// Why clang could not report its resource directory, including the hint
  /// Windows withholds: a process killed by `STATUS_DLL_NOT_FOUND` writes
  /// nothing to either stream, it only exits with the raw NTSTATUS.
  static String _clangFailureDetail(CapturedProcess? result, Object? failure) {
    if (result == null) return '\n$failure';
    final detail = <String>[
      '`clang -print-resource-dir` exited ${result.exitCode}.',
    ];
    for (final output in [result.stdout.trim(), result.stderr.trim()]) {
      if (output.isNotEmpty) detail.add(output);
    }
    final status = ProcessRunner.describeExitCode(result.exitCode);
    if (status != null) detail.add('That is $status.');
    if (result.exitCode == _statusDllNotFound ||
        result.exitCode == _statusDllNotFound - 0x100000000) {
      detail.add(
        'The Swift toolchain binaries cannot start because their runtime DLLs '
        'are not on PATH. Open a new terminal so the installer PATH applies, '
        r'or add %LOCALAPPDATA%\Programs\Swift\Runtimes\<version>\usr\bin to '
        'PATH.',
      );
    }
    return '\n${detail.join('\n')}';
  }

  /// The destination may be a real directory, a file, or a symlink Xcode
  /// shipped, so delete whichever kind is actually there.
  static Future<void> _deleteAnyEntity(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.link:
        await Link(path).delete();
      case FileSystemEntityType.file:
        await File(path).delete();
      default:
    }
  }
}
