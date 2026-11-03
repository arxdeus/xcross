import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/mach_o.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/static_framework_stubs.dart';

import '../../apple/support/native_test_file_system.dart';

const _plist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Kit</string>
  <key>MinimumOSVersion</key><string>12.0</string>
</dict>
</plist>
''';

void main() {
  late Directory tmp;
  late StaticFrameworkStubs stubs;
  const fs = NativeTestFileSystem();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('static_stubs_');
    stubs = StaticFrameworkStubs(
      fileSystem: fs,
      paths: p.context,
      copier: RecursiveDirectoryCopier(fileSystem: fs, paths: p.context),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String path, Object contents) {
    final file = File(path)..parent.createSync(recursive: true);
    contents is String
        ? file.writeAsStringSync(contents)
        : file.writeAsBytesSync(contents as List<int>);
  }

  /// A products directory as `swift build` leaves it.
  String products() {
    final debug = p.join(tmp.path, 'debug');
    write(p.join(debug, 'libFlutterPluginsGenerated.dylib'), 'dylib');
    final kit = p.join(debug, 'Kit.framework');
    write(p.join(kit, 'Kit'), '!<arch>\nobjects');
    write(p.join(kit, 'Info.plist'), _plist);
    write(p.join(kit, 'PrivacyInfo.xcprivacy'), '<plist/>');
    write(p.join(kit, 'Kit.bundle', 'PrivacyInfo.xcprivacy'), '<plist/>');
    write(p.join(kit, 'Headers', 'Kit.h'), '');
    write(p.join(kit, 'PrivateHeaders', 'KitP.h'), '');
    write(p.join(kit, 'Modules', 'module.modulemap'), '');
    // A dynamic framework is embedded elsewhere.
    final cast = Uint8List(32)
      ..buffer.asByteData().setUint32(0, 0xfeedfacf, Endian.little);
    write(p.join(debug, 'Cast.framework', 'Cast'), cast);
    // A fat static framework.
    final fat = Uint8List(64);
    fat.buffer.asByteData()
      ..setUint32(0, 0xcafebabe)
      ..setUint32(4, 1)
      ..setUint32(16, 40);
    fat.setRange(40, 48, '!<arch>\n'.codeUnits);
    write(p.join(debug, 'Fat.framework', 'Fat'), fat);
    return debug;
  }

  test('embeds Info.plist, resources and a stub binary only', () async {
    final debug = products();
    final frameworks = p.join(tmp.path, 'App', 'Frameworks');
    final embedded = await stubs.embedLinked(
      [p.join(debug, 'libFlutterPluginsGenerated.dylib')],
      frameworks,
      simulator: false,
      sdkVersion: '26.5',
    );
    expect(embedded.map(p.basename), ['Fat.framework', 'Kit.framework']);
    final kit = Directory(p.join(frameworks, 'Kit.framework'));
    final entries =
        kit
            .listSync(recursive: true)
            .map((e) => p.relative(e.path, from: kit.path))
            .toList()
          ..sort();
    expect(entries, [
      'Info.plist',
      'Kit',
      'Kit.bundle',
      p.join('Kit.bundle', 'PrivacyInfo.xcprivacy'),
      'PrivacyInfo.xcprivacy',
    ]);
    expect(File(p.join(kit.path, 'Info.plist')).readAsStringSync(), _plist);
    final binary = File(p.join(kit.path, 'Kit')).readAsBytesSync();
    final macho = MachOFile.parse(binary, invalid: (m) => throw StateError(m));
    expect(macho.fileType, MachOConstants.mhDylib);
    expect(macho.cpuType, MachOConstants.cpuTypeArm64);
    final build = macho.commands.singleWhere((c) => c.type == 0x32);
    final data = ByteData.sublistView(binary);
    expect(data.getUint32(build.offset + 8, Endian.little), 2);
    expect(data.getUint32(build.offset + 12, Endian.little), 0x0c0000);
    expect(data.getUint32(build.offset + 16, Endian.little), 0x1a0500);
    final id = macho.commands.singleWhere((c) => c.type == 0xd);
    expect(
      macho.nullTerminatedString(id.offset + 24, id.offset + id.size, 'name'),
      '@rpath/Kit.framework/Kit',
    );
    // Signed ad-hoc.
    expect(macho.commands.where((c) => c.type == 0x1d), hasLength(1));
  });

  test('simulator builds get the simulator platform', () async {
    final debug = products();
    final frameworks = p.join(tmp.path, 'Frameworks');
    await stubs.embed(
      [p.join(debug, 'Kit.framework')],
      frameworks,
      simulator: true,
    );
    final binary = File(
      p.join(frameworks, 'Kit.framework', 'Kit'),
    ).readAsBytesSync();
    final macho = MachOFile.parse(binary, invalid: (m) => throw StateError(m));
    final build = macho.commands.singleWhere((c) => c.type == 0x32);
    expect(
      ByteData.sublistView(binary).getUint32(build.offset + 8, Endian.little),
      StaticFrameworkStubs.platformIosSimulator,
    );
  });

  test('skips library xcframework products and embedded names', () async {
    final debug = products();
    write(p.join(debug, 'libKit.a'), '!<arch>\n');
    final frameworks = p.join(tmp.path, 'Frameworks');
    Directory(p.join(frameworks, 'Kit.framework')).createSync(recursive: true);
    final embedded = await stubs.embedLinked(
      [p.join(debug, 'libFlutterPluginsGenerated.dylib')],
      frameworks,
      simulator: false,
    );
    expect(embedded.map(p.basename), ['Fat.framework']);
  });

  test('sdkVersionOf reads the SDK name suffix', () {
    expect(StaticFrameworkStubs.sdkVersionOf('iphoneos26.5'), '26.5');
    expect(StaticFrameworkStubs.sdkVersionOf('iphonesimulator'), isNull);
  });

  test('codesign accepts the stub', () async {
    final stub = StaticFrameworkStubs.stubDylib(
      installName: '@rpath/Kit.framework/Kit',
      platform: StaticFrameworkStubs.platformIos,
      minimumOs: '12.0',
      sdk: '26.5',
    );
    final path = p.join(tmp.path, 'Kit');
    File(path).writeAsBytesSync(stub);
    for (final args in [
      ['--force', '--sign', '-', path],
      ['--verify', '--strict', path],
    ]) {
      final result = await Process.run('codesign', args);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }
    final otool = await Process.run('otool', ['-l', path]);
    expect(otool.stdout, contains('@rpath/Kit.framework/Kit'));
  }, testOn: 'mac-os');
}
