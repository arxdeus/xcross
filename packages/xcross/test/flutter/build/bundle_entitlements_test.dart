import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/mach_o_code_signature.dart';
import 'package:xcross/src/shared/artifact/app_capabilities.dart';
import 'package:xcross/src/shared/artifact/app_entitlements.dart';
import 'package:xcross/src/shared/flutter/build/bundle_entitlements.dart';
import 'package:xcross/src/shared/flutter/project/pbx_project_reader.dart';

import '../../apple/support/linkable_macho_fixture.dart';
import '../flutter_test_runtime.dart';

const _pbxproj = r'''
// !$*UTF8*$!
{
	objects = {
		AA01 = {
			isa = PBXNativeTarget;
			buildConfigurationList = BB01;
			name = Runner;
			productType = "com.apple.product-type.application";
		};
		AA02 = {
			isa = PBXNativeTarget;
			buildConfigurationList = BB02;
			name = Share;
			productType = "com.apple.product-type.app-extension";
		};
		CC01 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = Runner/RunnerDebug.entitlements;
			};
			name = Debug;
		};
		CC02 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = "$(TARGET_NAME)/Runner.entitlements";
				CUSTOM_GROUP_ID = "group.$(PRODUCT_BUNDLE_IDENTIFIER)";
			};
			name = Release;
		};
		CC03 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = Share/Share.entitlements;
			};
			name = Release;
		};
		BB01 = {
			isa = XCConfigurationList;
			buildConfigurations = (CC01, CC02);
		};
		BB02 = {
			isa = XCConfigurationList;
			buildConfigurations = (CC03);
		};
	};
}
''';

@internal
PlatformHostInterface testHost() => Platform.isWindows
    ? WindowsHost(currentDirectory: Directory.current.path)
    : Platform.isMacOS
    ? MacOSHost()
    : LinuxHost();

String _plist(Map<String, Object?> map) =>
    PropertyListSerialization.stringWithPropertyList(map);

void main() {
  late Directory root;
  late String app;
  late List<String> warnings;
  late BundleEntitlements entitlements;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bundle-entitlements');
    final ios = p.join(root.path, 'ios');
    Directory(p.join(ios, 'Runner.xcodeproj')).createSync(recursive: true);
    File(
      p.join(ios, 'Runner.xcodeproj', 'project.pbxproj'),
    ).writeAsStringSync(_pbxproj);
    Directory(p.join(ios, 'Runner')).createSync();
    File(p.join(ios, 'Runner', 'Runner.entitlements')).writeAsStringSync(
      _plist({
        'aps-environment': 'production',
        'com.apple.developer.associated-domains': [
          'applinks:example.com',
          'webcredentials:example.com',
        ],
        'com.apple.security.application-groups': [r'$(CUSTOM_GROUP_ID)'],
        'keychain-access-groups': [r'$(AppIdentifierPrefix)com.example.app'],
      }),
    );
    app = p.join(root.path, 'build', 'Runner.app');
    Directory(
      p.join(app, 'PlugIns', 'Share.appex'),
    ).createSync(recursive: true);
    File(p.join(app, 'Info.plist')).writeAsStringSync(
      _plist({
        'CFBundleExecutable': 'Runner',
        'CFBundleIdentifier': 'com.example.app',
      }),
    );
    File(p.join(app, 'Runner')).writeAsBytesSync(linkableMachO());
    File(p.join(app, 'PlugIns', 'Share.appex', 'Info.plist')).writeAsStringSync(
      _plist({
        'CFBundleExecutable': 'Share',
        'CFBundleIdentifier': 'com.example.app.Share',
      }),
    );
    File(
      p.join(app, 'PlugIns', 'Share.appex', 'Share'),
    ).writeAsBytesSync(linkableMachO());
    warnings = [];
    final host = testHost();
    entitlements = BundleEntitlements(
      fileSystem: host.fileSystem,
      paths: host.paths.context,
      projects: PbxProjectReader(host.fileSystem, host.paths.context),
      log: Log(output: CaptureLog(warnings)),
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('embeds the Release entitlements with variables expanded', () async {
    final resolved = entitlements.resolve(
      projectRoot: root.path,
      bundleDir: app,
      configuration: 'Release',
    );
    // The extension's file is missing: warned, not fatal.
    expect(resolved.map((e) => e.identifier), ['com.example.app']);
    expect(warnings.single, contains('Share.entitlements'));
    expect(resolved.single.entitlements, {
      'aps-environment': 'production',
      'com.apple.developer.associated-domains': [
        'applinks:example.com',
        'webcredentials:example.com',
      ],
      'com.apple.security.application-groups': ['group.com.example.app'],
    });

    final signed = await entitlements.embed(resolved);
    expect(signed, [p.join(app, 'Runner')]);
    final bytes = File(p.join(app, 'Runner')).readAsBytesSync();
    final xml = MachOCodeSignature.embeddedEntitlementsXml(bytes)!;
    expect(xml, contains('applinks:example.com'));
    expect(xml, isNot(contains(r'$(')));
    _expectSpecialSlots(
      bytes,
      File(p.join(app, 'Info.plist')).readAsBytesSync(),
    );

    // `xcross flutter run` reads the hand-off back from the signature.
    final host = testHost();
    final declared = AppEntitlements(
      fileSystem: host.fileSystem,
      paths: host.paths,
    ).of(app);
    expect(declared['aps-environment'], 'production');
    expect(
      AppCapabilities(fileSystem: host.fileSystem, paths: host.paths).of(app),
      containsAll(['PUSH_NOTIFICATIONS', 'ASSOCIATED_DOMAINS', 'APP_GROUPS']),
    );
    // No private key was written into the deliverable's Info.plist.
    expect(
      File(p.join(app, 'Info.plist')).readAsStringSync(),
      isNot(contains('XCross')),
    );
  });

  test('signs app extensions with their own entitlements', () async {
    File(p.join(root.path, 'ios', 'Share', 'Share.entitlements'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        _plist({
          'com.apple.security.application-groups': ['group.com.example'],
        }),
      );
    final resolved = entitlements.resolve(
      projectRoot: root.path,
      bundleDir: app,
      configuration: 'Release',
    );
    await entitlements.embed(resolved);
    final share = File(p.join(app, 'PlugIns', 'Share.appex', 'Share'));
    expect(
      MachOCodeSignature.embeddedEntitlementsXml(share.readAsBytesSync()),
      contains('group.com.example'),
    );
    // `_provisionExtensions` reads each extension's own signature.
    final host = testHost();
    final extension = p.join(app, 'PlugIns', 'Share.appex');
    expect(
      AppEntitlements(
        fileSystem: host.fileSystem,
        paths: host.paths,
      ).of(extension)['com.apple.security.application-groups'],
      ['group.com.example'],
    );
    expect(
      AppCapabilities(
        fileSystem: host.fileSystem,
        paths: host.paths,
      ).of(extension),
      contains('APP_GROUPS'),
    );
  });

  test('only device builds embed entitlements', () {
    expect(testIPhoneRuntime().policy.embedsEntitlements, isTrue);
    expect(testSimulatorRuntime().policy.embedsEntitlements, isFalse);
  });

  test('falls back to the preferred configuration only when it exists', () {
    File(
      p.join(root.path, 'ios', 'Runner', 'RunnerDebug.entitlements'),
    ).writeAsStringSync('not a plist');
    final resolved = entitlements.resolve(
      projectRoot: root.path,
      bundleDir: app,
      configuration: 'Debug',
    );
    expect(resolved.where((e) => e.identifier == 'com.example.app'), isEmpty);
    expect(warnings.any((w) => w.contains('not a valid plist')), isTrue);
  });

  group('entitlements files from Windows checkouts', () {
    final xml = _plist({'aps-environment': 'development'});
    final crlf = xml.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');

    test('parses CRLF line endings', () {
      expect(
        BundleEntitlements.parsePlist(Uint8List.fromList(utf8.encode(crlf))),
        {'aps-environment': 'development'},
      );
    });

    test('strips a UTF-8 byte-order mark', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(crlf)];
      expect(BundleEntitlements.parsePlist(Uint8List.fromList(bytes)), {
        'aps-environment': 'development',
      });
    });

    test('reads binary plists', () {
      final data = PropertyListSerialization.dataWithPropertyList({
        'aps-environment': 'development',
      });
      expect(BundleEntitlements.parsePlist(Uint8List.sublistView(data)), {
        'aps-environment': 'development',
      });
    });

    test('a BOM-prefixed entitlements file is embedded', () {
      File(
        p.join(root.path, 'ios', 'Runner', 'Runner.entitlements'),
      ).writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(crlf)]);
      final resolved = entitlements.resolve(
        projectRoot: root.path,
        bundleDir: app,
        configuration: 'Release',
      );
      expect(resolved.first.entitlements, {'aps-environment': 'development'});
    });
  });

  test('an emptied array survives only if it was empty', () {
    expect(BundleEntitlements.expandValue(<Object?>[], const {}), isEmpty);
    expect(
      BundleEntitlements.expandValue([r'$(AppIdentifierPrefix)x'], const {}),
      isNull,
    );
  });

  test('a linker-only signature yields no entitlements', () {
    expect(MachOCodeSignature.embeddedEntitlementsXml(linkableMachO()), isNull);
    expect(MachOCodeSignature.embeddedEntitlementsXml(Uint8List(8)), isNull);
  });
}

void _expectSpecialSlots(Uint8List bytes, List<int> infoPlist) {
  final data = ByteData.sublistView(bytes);
  var command = 32;
  var dataOffset = 0;
  for (var index = 0; index < data.getUint32(16, Endian.little); index++) {
    if (data.getUint32(command, Endian.little) == 0x1d) {
      dataOffset = data.getUint32(command + 8, Endian.little);
    }
    command += data.getUint32(command + 4, Endian.little);
  }
  final count = data.getUint32(dataOffset + 8);
  final blobs = <int, Uint8List>{};
  for (var index = 0; index < count; index++) {
    final type = data.getUint32(dataOffset + 12 + index * 8);
    final start = dataOffset + data.getUint32(dataOffset + 16 + index * 8);
    blobs[type] = bytes.sublist(start, start + data.getUint32(start + 4));
  }
  final directory = ByteData.sublistView(blobs[0]!);
  expect(directory.getUint32(12) & 0x2, 0x2);
  final hashOffset = directory.getUint32(16);
  List<int> slot(int n) =>
      blobs[0]!.sublist(hashOffset - n * 32, hashOffset - (n - 1) * 32);
  expect(slot(1), sha256.convert(infoPlist).bytes);
  expect(slot(5), sha256.convert(blobs[5]!).bytes);
  expect(slot(7), sha256.convert(blobs[7]!).bytes);
  final codeLimit = directory.getUint32(32);
  for (var page = 0; page * 4096 < codeLimit; page++) {
    final end = (page + 1) * 4096 < codeLimit ? (page + 1) * 4096 : codeLimit;
    expect(
      blobs[0]!.sublist(hashOffset + page * 32, hashOffset + page * 32 + 32),
      sha256.convert(bytes.sublist(page * 4096, end)).bytes,
    );
  }
}

@internal
final class CaptureLog implements LogOutput {
  CaptureLog(this.lines);
  final List<String> lines;
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) {}
  @override
  void stderr(String message) => lines.add(message);
  @override
  void write(String message) {}
}
