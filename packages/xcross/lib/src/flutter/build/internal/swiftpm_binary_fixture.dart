import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

final class SwiftPmBinaryFixture {
  const SwiftPmBinaryFixture({
    required this.pluginRoot,
    required this.archive,
    required this.checksum,
  });

  final Directory pluginRoot;
  final File archive;
  final String checksum;

  factory SwiftPmBinaryFixture.generate({
    required String root,
    required Uri archiveUrl,
  }) {
    final output = Directory(root)..createSync(recursive: true);
    final plugin = Directory(p.join(output.path, 'binary_fixture_plugin'))
      ..createSync(recursive: true);
    final archive = File(p.join(output.path, 'BinaryFixture.zip'));
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

    File(p.join(plugin.path, 'pubspec.yaml')).writeAsStringSync('''
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
''');
    final swiftPackage = Directory(
      p.join(plugin.path, 'ios', 'binary_fixture_plugin'),
    )..createSync(recursive: true);
    File(p.join(swiftPackage.path, 'Package.swift')).writeAsStringSync('''
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
    final sources = Directory(
      p.join(swiftPackage.path, 'Sources', 'binary_fixture_plugin'),
    )..createSync(recursive: true);
    File(p.join(sources.path, 'BinaryFixturePlugin.swift')).writeAsStringSync(
      '''
import Flutter
import UIKit
public final class BinaryFixturePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
''',
    );
    return SwiftPmBinaryFixture(
      pluginRoot: plugin,
      archive: archive,
      checksum: checksum,
    );
  }

  static Directory generateXcframework<T extends PlatformHostInterface>({
    required SwiftPmArtifactFileSystem fileSystem,
    required String root,
    required String name,
    required FlutterTargetBuildPolicy<T> policy,
  }) {
    const candidates = <({String identifier, String? variant})>[
      (identifier: 'ios-arm64', variant: null),
      (identifier: 'ios-arm64-simulator', variant: 'simulator'),
    ];
    final matching = candidates
        .where((candidate) => policy.matchesLibraryVariant(candidate.variant))
        .toList();
    if (matching.length != 1) {
      throw ArgumentError(
        'Gate fixture requires exactly one matching target library variant',
      );
    }
    final library = matching.single;
    final framework = fileSystem.directory(p.join(root, '$name.xcframework'));
    fileSystem.file(p.join(framework.path, 'Info.plist'))
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
        p.join(framework.path, library.identifier, '$name.framework', name),
      )
      ..createSync(recursive: true)
      ..writeAsBytesSync(_emptyMachO());
    return framework;
  }

  static File archiveXcframework({
    required SwiftPmArtifactFileSystem fileSystem,
    required Directory framework,
    required String output,
  }) {
    final archive = Archive();
    for (final entity in framework.listSync(recursive: true)) {
      if (entity is! File) continue;
      final name = p.relative(entity.path, from: framework.parent.path);
      archive.addFile(
        ArchiveFile(name, entity.lengthSync(), entity.readAsBytesSync())
          ..lastModTime = 0,
      );
    }
    return fileSystem.file(output)
      ..writeAsBytesSync(ZipEncoder().encode(archive), flush: true);
  }

  static void writeGatePackage({
    required SwiftPmArtifactFileSystem fileSystem,
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
    fileSystem.file(p.join(root, 'Sources', 'GateProbe', 'GateProbe.swift'))
      ..createSync(recursive: true)
      ..writeAsStringSync('public enum GateProbe {}\n');
    fileSystem.file(p.join(root, 'Package.swift')).writeAsStringSync('''
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
