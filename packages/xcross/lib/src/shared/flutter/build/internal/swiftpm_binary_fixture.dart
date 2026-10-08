import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';

@internal
final class SwiftPmBinaryFixture {
  const SwiftPmBinaryFixture({
    required this.pluginRoot,
    required this.archive,
    required this.checksum,
  });

  final Directory pluginRoot;
  final File archive;
  final String checksum;
}

@internal
final class SwiftPmBinaryFixtureLibrary {
  const SwiftPmBinaryFixtureLibrary({required this.identifier, this.variant});
  final String identifier;
  final String? variant;
}

@internal
final class SwiftPmBinaryFixtureGenerator {
  const SwiftPmBinaryFixtureGenerator({
    required this.fileSystem,
    required this.paths,
  });
  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  SwiftPmBinaryFixture generate({
    required String root,
    required Uri archiveUrl,
  }) {
    fileSystem.directory(root).createSync(recursive: true);
    final pluginPath = paths.join(root, 'binary_fixture_plugin');
    final plugin = fileSystem.directory(pluginPath)
      ..createSync(recursive: true);
    final archive = fileSystem.file(paths.join(root, 'BinaryFixture.zip'));
    final entries = <String, List<int>>{
      'BinaryFixture.xcframework/Info.plist': Uint8List.fromList(
        PropertyListSerialization.stringWithPropertyList({
          'AvailableLibraries': [
            {
              'LibraryIdentifier': 'ios-arm64',
              'LibraryPath': 'BinaryFixture.framework',
              'SupportedArchitectures': ['arm64'],
              'SupportedPlatform': 'ios',
            },
          ],
          'CFBundlePackageType': 'XFWK',
          'XCFrameworkFormatVersion': '1.0',
        }).codeUnits,
      ),
      'BinaryFixture.xcframework/ios-arm64/BinaryFixture.framework/BinaryFixture':
          _emptyMachO(),
    };
    final zip = Archive();
    for (final name in entries.keys.toList()..sort()) {
      zip.addFile(
        ArchiveFile(name, entries[name]!.length, entries[name]!)
          ..lastModTime = 0,
      );
    }
    archive.writeAsBytesSync(ZipEncoder().encode(zip), flush: true);
    final checksum = sha256.convert(archive.readAsBytesSync()).toString();

    fileSystem.file(paths.join(pluginPath, 'pubspec.yaml')).writeAsStringSync(
      '''
name: binary_fixture_plugin
description: Generated SwiftPM binary artifact integration fixture.
version: 0.0.1
publish_to: none
environment:
  sdk: ^3.10.0
dependencies:
  flutter:
    sdk: flutter
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: BinaryFixturePlugin
''',
    );
    final swiftPackagePath = paths.join(
      pluginPath,
      'ios',
      'binary_fixture_plugin',
    );
    fileSystem.directory(swiftPackagePath).createSync(recursive: true);
    fileSystem
        .file(paths.join(swiftPackagePath, 'Package.swift'))
        .writeAsStringSync('''
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
  name: "binary_fixture_plugin",
  platforms: [.iOS(.v13)],
  products: [.library(name: "binary-fixture-plugin", type: .dynamic, targets: ["binary_fixture_plugin"])],
  targets: [
    .binaryTarget(name: "BinaryFixture", url: "$archiveUrl", checksum: "$checksum"),
    .target(name: "binary_fixture_plugin", dependencies: ["BinaryFixture"])
  ]
)
''');
    final sourcesPath = paths.join(
      swiftPackagePath,
      'Sources',
      'binary_fixture_plugin',
    );
    fileSystem.directory(sourcesPath).createSync(recursive: true);
    fileSystem
        .file(paths.join(sourcesPath, 'BinaryFixturePlugin.swift'))
        .writeAsStringSync('''
import Flutter
import UIKit
public final class BinaryFixturePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
''');
    return SwiftPmBinaryFixture(
      pluginRoot: plugin,
      archive: archive,
      checksum: checksum,
    );
  }

  Directory generateXcframework({
    required String root,
    required String name,
    required SwiftPmBinaryFixtureLibrary library,
  }) {
    final frameworkPath = paths.join(root, '$name.xcframework');
    final framework = fileSystem.directory(frameworkPath);
    fileSystem.file(paths.join(frameworkPath, 'Info.plist'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        PropertyListSerialization.stringWithPropertyList({
          'AvailableLibraries': [
            {
              'LibraryIdentifier': library.identifier,
              'LibraryPath': '$name.framework',
              'SupportedArchitectures': ['arm64'],
              'SupportedPlatform': 'ios',
              if (library.variant != null)
                'SupportedPlatformVariant': library.variant!,
            },
          ],
          'CFBundlePackageType': 'XFWK',
          'XCFrameworkFormatVersion': '1.0',
        }),
      );
    fileSystem.file(
        paths.join(frameworkPath, library.identifier, '$name.framework', name),
      )
      ..createSync(recursive: true)
      ..writeAsBytesSync(_emptyMachO());
    return framework;
  }

  File archiveXcframework({
    required Directory framework,
    required String output,
  }) {
    final archive = Archive();
    final files =
        framework
            .listSync(recursive: true)
            .whereType<File>()
            .map(
              (entity) => (
                name: paths
                    .relative(entity.path, from: framework.parent.path)
                    .replaceAll(r'\', '/'),
                file: entity,
              ),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    for (final entry in files) {
      archive.addFile(
        ArchiveFile(
          entry.name,
          entry.file.lengthSync(),
          entry.file.readAsBytesSync(),
        )..lastModTime = 0,
      );
    }
    return fileSystem.file(output)
      ..writeAsBytesSync(ZipEncoder().encode(archive), flush: true);
  }

  void writeGatePackage({
    required String root,
    required String targetName,
    String? path,
    Uri? url,
    String? checksum,
  }) {
    if ((path == null) == (url == null || checksum == null)) {
      throw ArgumentError('Specify either path or URL and checksum');
    }
    final binaryTarget = path != null
        ? '.binaryTarget(name: "$targetName", path: "$path")'
        : '.binaryTarget(name: "$targetName", url: "$url", checksum: "$checksum")';
    fileSystem.file(paths.join(root, 'Sources', 'GateProbe', 'GateProbe.swift'))
      ..createSync(recursive: true)
      ..writeAsStringSync('public enum GateProbe {}\n');
    fileSystem.file(paths.join(root, 'Package.swift')).writeAsStringSync('''
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Gate", products: [.library(name: "Gate", targets: ["GateProbe"])], targets: [$binaryTarget, .target(name: "GateProbe", dependencies: ["$targetName"])])
''');
  }

  static Uint8List _emptyMachO() {
    final bytes = Uint8List(32);
    final data = ByteData.sublistView(bytes);
    data
      ..setUint32(0, 0xfeedfacf, Endian.little)
      ..setUint32(4, 0x0100000c, Endian.little)
      ..setUint32(12, 1, Endian.little);
    List<int> member(String name, List<int> content) {
      final encodedName = utf8.encode('$name\u0000');
      final size = encodedName.length + content.length;
      final member = <int>[
        ...utf8.encode('#1/${encodedName.length}'.padRight(16)),
        ...utf8.encode('0'.padRight(12)),
        ...utf8.encode('0'.padRight(6)),
        ...utf8.encode('0'.padRight(6)),
        ...utf8.encode('100644'.padRight(8)),
        ...utf8.encode('$size'.padRight(10)),
        0x60,
        0x0a,
        ...encodedName,
        ...content,
      ];
      if (member.length.isOdd) member.add(0x0a);
      return member;
    }

    final index = ByteData(8);
    return Uint8List.fromList([
      ...utf8.encode('!<arch>\n'),
      ...member('__.SYMDEF', index.buffer.asUint8List()),
      ...member('fixture.o', bytes),
    ]);
  }
}
