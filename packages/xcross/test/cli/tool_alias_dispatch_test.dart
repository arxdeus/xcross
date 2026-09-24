import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/xcross.dart';

void main() {
  test(
    'dispatches a prepared Windows alias through its trusted mapping',
    () async {
      String? executable;
      List<String>? forwarded;

      final code = await runPreparedToolAlias(
        ['-dead_strip', 'path with spaces'],
        executablePath: r'C:\prepared\bin\ld.exe',
        environment: const {
          'XCROSS_APPLE_TOOL_LD': r'C:\LLVM\bin\ld64.lld.exe',
        },
        run: (target, arguments) async {
          executable = target;
          forwarded = arguments;
          return 7;
        },
      );

      expect(code, 7);
      expect(executable, r'C:\LLVM\bin\ld64.lld.exe');
      expect(forwarded, ['-dead_strip', 'path with spaces']);
    },
  );

  test('dispatches native asset aliases through sidecar mappings', () async {
    final temp = Directory.systemTemp.createTempSync('xcross_tool_alias_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final alias = File(p.join(temp.path, 'cc.exe'))..writeAsStringSync('alias');
    File('${alias.path}.path').writeAsStringSync(r'C:\LLVM\clang.exe');
    File(
      '${alias.path}.args',
    ).writeAsStringSync(r'["-isysroot","C:\\SDK","-Wl,-arch,arm64"]');

    String? executable;
    List<String>? forwarded;
    final code = await runPreparedToolAlias(
      ['--target=aarch64-apple-ios', '--version'],
      executablePath: alias.path,
      environment: const {},
      run: (target, arguments) async {
        executable = target;
        forwarded = arguments;
        return 0;
      },
    );

    expect(code, 0);
    expect(executable, r'C:\LLVM\clang.exe');
    expect(forwarded, [
      '-isysroot',
      r'C:\SDK',
      '-Wl,-arch,arm64',
      '--target=aarch64-apple-ios',
      '--version',
    ]);
  });

  test('plutil replaces MinimumOSVersion for Flutter assemble', () async {
    final temp = Directory.systemTemp.createTempSync('xcross_plutil_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final plist = File(p.join(temp.path, 'Info.plist'))
      ..writeAsStringSync('''
<plist><dict>
<key>MinimumOSVersion</key>
<string>12.0</string>
</dict></plist>
''');

    expect(
      await runPreparedToolAlias([
        '-replace',
        'MinimumOSVersion',
        '-string',
        '15.0',
        plist.path,
      ], executablePath: p.join(temp.path, 'plutil')),
      0,
    );
    expect(plist.readAsStringSync(), contains('<string>15.0</string>'));
  });

  test('does not intercept the normal xcross executable', () async {
    expect(
      await runPreparedToolAlias(
        const [],
        executablePath: '/bundle/bin/xcross',
        environment: const {},
        run: (_, __) async => fail('must not run'),
      ),
      isNull,
    );
  });

  test('runs dsymutil normally when the mapped executable exists', () async {
    final temp = Directory.systemTemp.createTempSync('xcross_dsymutil_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final dsymutil = File(p.join(temp.path, 'dsymutil.exe'))
      ..writeAsStringSync('fake');
    var invoked = false;

    final code = await runPreparedToolAlias(
      ['framework/Binary', '-o', 'framework.dSYM'],
      executablePath: r'C:\prepared\bin\dsymutil.exe',
      environment: {'XCROSS_APPLE_TOOL_DSYMUTIL': dsymutil.path},
      run: (target, arguments) async {
        invoked = true;
        return 0;
      },
    );

    expect(code, 0);
    expect(invoked, isTrue);
  });

  test('no-ops dsymutil instead of failing the build when the mapped '
      'executable does not exist', () async {
    // The swift.org Windows LLVM installer's LLVM/bin ships ld64.lld.exe
    // and llvm-strip.exe but no dsymutil.exe (confirmed against a real
    // CI run). Kotlin/Native's MacOSBasedLinker calls dsymutil
    // unconditionally after every framework link and fails the whole
    // compile on a nonzero exit, so a missing dsymutil must not crash
    // Process.start — it should degrade to a silent success instead.
    final code = await runPreparedToolAlias(
      ['framework/Binary', '-o', 'framework.dSYM'],
      executablePath: r'C:\prepared\bin\dsymutil.exe',
      environment: const {
        'XCROSS_APPLE_TOOL_DSYMUTIL': r'C:\Program Files\LLVM\bin\dsymutil.exe',
      },
      run: (_, __) async => fail('must not run a nonexistent executable'),
    );

    expect(code, 0);
  });

  test('falls back to llvm-ar when llvm-libtool-darwin is missing', () async {
    final temp = Directory.systemTemp.createTempSync('xcross_libtool_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final ar = File(p.join(temp.path, 'llvm-ar'))..writeAsStringSync('');
    final list = File(p.join(temp.path, 'libraries'))
      ..writeAsStringSync('a.a\nb.a\n');
    String? executable;
    List<String>? forwarded;

    final code = await runPreparedToolAlias(
      [
        '-D',
        '-static',
        '-o',
        p.join(temp.path, 'Out'),
        '-arch_only',
        'arm64',
        'main.o',
        '-filelist',
        list.path,
      ],
      executablePath: '/prepared/bin/libtool',
      environment: {
        'XCROSS_APPLE_TOOL_LIBTOOL': p.join(temp.path, 'llvm-libtool-darwin'),
      },
      run: (target, arguments) async {
        executable = target;
        forwarded = arguments;
        return 0;
      },
    );

    expect(code, 0);
    expect(executable, ar.path);
    expect(forwarded, [
      'qLsD',
      '--format=darwin',
      p.join(temp.path, 'Out'),
      'main.o',
      'a.a',
      'b.a',
    ]);
  });

  test('passes the arm64 slice of a universal archive to llvm-ar', () {
    final temp = Directory.systemTemp.createTempSync('xcross_libtool_fat_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final slice = [0x21, 0x3c, 0x61, 0x72, 0x63, 0x68, 0x3e, 0x0a];
    final header = ByteData(28)
      ..setUint32(0, 0xcafebabe)
      ..setUint32(4, 1)
      ..setUint32(8, 0x0100000c)
      ..setUint32(16, 28)
      ..setUint32(20, slice.length);
    final fat = File(p.join(temp.path, 'libfat.a'))
      ..writeAsBytesSync([...header.buffer.asUint8List(), ...slice]);
    final output = p.join(temp.path, 'Out');

    final args = libtoolAsArArguments(['-static', '-o', output, fat.path])!;

    expect(args.take(3), ['qLsD', '--format=darwin', output]);
    expect(File(args.last).readAsBytesSync(), slice);
  });
}
