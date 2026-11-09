import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/swiftpm/product_embedder.dart';
import 'package:xcross/src/shared/swiftpm/recursive_directory_copy.dart';
import 'package:xcross/src/shared/swiftpm/swift_back_deploy_libraries.dart';

import '../apple/support/native_test_file_system.dart';

const _arm64 = 0x0100_000C;
const _x86_64 = 0x0100_0007;

/// A minimal 64-bit Mach-O dylib for [cpu]/[subtype] loading [loads]
/// (`LC_LOAD_DYLIB`) and [weak] (`LC_LOAD_WEAK_DYLIB`).
@internal
Uint8List machO({
  int cpu = _arm64,
  int subtype = 0,
  List<String> loads = const [],
  List<String> weak = const [],
}) {
  final commands = BytesBuilder();
  var count = 0;
  void dylib(int type, String name) {
    final encoded = utf8.encode(name);
    final size = (24 + encoded.length + 1 + 7) & ~7;
    final command = ByteData(size)
      ..setUint32(0, type, Endian.little)
      ..setUint32(4, size, Endian.little)
      ..setUint32(8, 24, Endian.little);
    final bytes = command.buffer.asUint8List()
      ..setRange(24, 24 + encoded.length, encoded);
    commands.add(bytes);
    count++;
  }

  for (final name in loads) {
    dylib(0xC, name);
  }
  for (final name in weak) {
    dylib(0x8000_0018, name);
  }
  final body = commands.takeBytes();
  final header = ByteData(32)
    ..setUint32(0, 0xFEED_FACF, Endian.little)
    ..setUint32(4, cpu, Endian.little)
    ..setUint32(8, subtype, Endian.little)
    ..setUint32(12, 0x6, Endian.little)
    ..setUint32(16, count, Endian.little)
    ..setUint32(20, body.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...body, 0, 0]);
}

/// A universal file of [slices] (each `(cpu, subtype, bytes)`).
@internal
Uint8List fat(List<(int, int, Uint8List)> slices) {
  const align = 0x1000;
  final header = ByteData(8 + 20 * slices.length)
    ..setUint32(0, 0xCAFE_BABE)
    ..setUint32(4, slices.length);
  final out = BytesBuilder();
  var offset = align;
  final placed = <(int, Uint8List)>[];
  for (var i = 0; i < slices.length; i++) {
    final (cpu, subtype, bytes) = slices[i];
    header
      ..setUint32(8 + i * 20, cpu)
      ..setUint32(12 + i * 20, subtype)
      ..setUint32(16 + i * 20, offset)
      ..setUint32(20 + i * 20, bytes.length)
      ..setUint32(24 + i * 20, 12);
    placed.add((offset, bytes));
    offset = (offset + bytes.length + align - 1) & ~(align - 1);
  }
  final file = Uint8List(offset)..setAll(0, header.buffer.asUint8List());
  for (final (start, bytes) in placed) {
    file.setAll(start, bytes);
  }
  out.add(file);
  return out.takeBytes();
}

void main() {
  late Directory tmp;
  late String app;
  late String sdkRoot;
  late String sdkPath;
  const fs = NativeTestFileSystem();
  final libraries = SwiftBackDeployLibraries(fs, p.context);
  final warnings = <String>[];

  void write(String path, List<int> bytes) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  String backDeploy(String version, String platform, String name) => p.join(
    sdkRoot,
    'Developer',
    'Toolchains',
    'XcodeDefault.xctoolchain',
    'usr',
    'lib',
    'swift-$version',
    platform,
    name,
  );

  Map<String, String> tree(String root) => {
    for (final entity in Directory(root).listSync(recursive: true))
      if (entity is File)
        p.relative(entity.path, from: root): base64.encode(
          entity.readAsBytesSync(),
        ),
  };

  final spanDevice = fat([
    (_arm64, 0, machO(loads: ['/usr/lib/swift/libswiftCore.dylib'])),
    (_arm64, 2, machO(subtype: 2)),
  ]);
  final spanSimulator = fat([
    (_x86_64, 3, machO(cpu: _x86_64, subtype: 3)),
    (_arm64, 0, machO()),
  ]);

  setUp(() {
    warnings.clear();
    tmp = Directory.systemTemp.createTempSync('back_deploy_');
    app = p.join(tmp.path, 'App.app');
    sdkRoot = p.join(tmp.path, 'xcross-darwin.artifactbundle');
    sdkPath = p.join(
      sdkRoot,
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
      'iPhoneOS.sdk',
    );
    Directory(sdkPath).createSync(recursive: true);
    write(
      backDeploy('6.2', 'iphoneos', 'libswiftCompatibilitySpan.dylib'),
      spanDevice,
    );
    write(
      backDeploy('6.2', 'iphonesimulator', 'libswiftCompatibilitySpan.dylib'),
      spanSimulator,
    );
    write(backDeploy('5.5', 'iphoneos', 'libswift_Concurrency.dylib'), machO());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<List<String>> embed({String sdkName = 'iphoneos26.5', String? sdk}) =>
      SwiftPmProductEmbedder(
        fs,
        p.context,
        copier: RecursiveDirectoryCopier(fileSystem: fs, paths: p.context),
      ).embedSwiftBackDeployLibraries(
        app,
        sdkName: sdkName,
        sdkPath: sdk ?? sdkPath,
        warn: warnings.add,
      );

  test('locates the bundle root of a platform SDK', () {
    expect(SwiftBackDeployLibraries.sdkRootOf(p.context, sdkPath), sdkRoot);
    expect(SwiftBackDeployLibraries.platformOf('iphoneos26.5'), 'iphoneos');
    expect(
      SwiftBackDeployLibraries.platformOf('iphonesimulator26.5'),
      'iphonesimulator',
    );
  });

  test('embeds the library a framework weakly links, thinned to the '
      'app executable', () async {
    write(p.join(app, 'Runner'), machO());
    write(
      p.join(app, 'Frameworks', 'Pkg.framework', 'Pkg'),
      machO(
        loads: ['/usr/lib/swift/libswiftCore.dylib'],
        weak: ['@rpath/libswiftCompatibilitySpan.dylib'],
      ),
    );
    final written = await embed();
    final copied = p.join(app, 'Frameworks', 'libswiftCompatibilitySpan.dylib');
    expect(written, [copied]);
    // The arm64 slice of the device library, the Runner's architecture.
    final slice = File(copied).readAsBytesSync();
    expect(
      ByteData.sublistView(slice).getUint32(0, Endian.little),
      0xFEED_FACF,
    );
    expect(ByteData.sublistView(slice).getUint32(8, Endian.little), 0);
    expect(
      slice.length,
      machO(loads: ['/usr/lib/swift/libswiftCore.dylib']).length,
    );
    expect(warnings, isEmpty);
  });

  test('takes the simulator library for a simulator build', () async {
    write(
      p.join(app, 'Runner'),
      machO(weak: ['@rpath/libswiftCompatibilitySpan.dylib']),
    );
    await embed(sdkName: 'iphonesimulator26.5');
    final copied = File(
      p.join(app, 'Frameworks', 'libswiftCompatibilitySpan.dylib'),
    ).readAsBytesSync();
    expect(copied, machO());
  });

  test('keeps a universal library whole when the app has no executable '
      'to thin to', () async {
    write(
      p.join(app, 'Frameworks', 'Pkg.framework', 'Pkg'),
      machO(weak: ['@rpath/libswiftCompatibilitySpan.dylib']),
    );
    await embed();
    expect(
      File(
        p.join(app, 'Frameworks', 'libswiftCompatibilitySpan.dylib'),
      ).readAsBytesSync(),
      spanDevice,
    );
  });

  test(
    'embeds an older back-deployment library from its own directory',
    () async {
      write(
        p.join(app, 'Runner'),
        machO(loads: ['@rpath/libswift_Concurrency.dylib']),
      );
      await embed();
      expect(
        File(
          p.join(app, 'Frameworks', 'libswift_Concurrency.dylib'),
        ).existsSync(),
        isTrue,
      );
    },
  );

  test('leaves a bundle without @rpath Swift references untouched', () async {
    write(
      p.join(app, 'Runner'),
      machO(
        loads: [
          '/usr/lib/swift/libswiftCore.dylib',
          '@rpath/Flutter.framework/Flutter',
        ],
      ),
    );
    write(
      p.join(app, 'Frameworks', 'Pkg.framework', 'Pkg'),
      machO(loads: ['/usr/lib/swift/libswift_Concurrency.dylib']),
    );
    write(p.join(app, 'Frameworks', 'Pkg.framework', 'Info.plist'), [1, 2, 3]);
    final before = tree(app);
    expect(await embed(), isEmpty);
    expect(tree(app), before);
    expect(warnings, isEmpty);
  });

  test(
    'warns and asks for a reinstall when the SDK predates the libraries',
    () async {
      Directory(
        p.join(sdkRoot, 'Developer', 'Toolchains'),
      ).deleteSync(recursive: true);
      write(
        p.join(app, 'Runner'),
        machO(weak: ['@rpath/libswiftCompatibilitySpan.dylib']),
      );
      expect(await embed(), isEmpty);
      expect(Directory(p.join(app, 'Frameworks')).existsSync(), isFalse);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('libswiftCompatibilitySpan.dylib'));
      expect(warnings.single, contains('xcross sdk install'));
    },
  );

  test('scans fat binaries and ignores files that are not Mach-O', () async {
    write(
      p.join(app, 'Runner'),
      fat([
        (_arm64, 0, machO(weak: ['@rpath/libswiftCompatibilitySpan.dylib'])),
      ]),
    );
    write(
      p.join(app, 'Frameworks', 'notes.txt'),
      utf8.encode('@rpath/libswiftX.dylib'),
    );
    await libraries.embed(
      bundleDir: app,
      sdkRoot: sdkRoot,
      platform: 'iphoneos',
      warn: warnings.add,
    );
    expect(
      File(
        p.join(app, 'Frameworks', 'libswiftCompatibilitySpan.dylib'),
      ).existsSync(),
      isTrue,
    );
    expect(warnings, isEmpty);
  });
}
