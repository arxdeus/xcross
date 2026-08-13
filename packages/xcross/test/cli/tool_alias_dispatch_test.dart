import 'dart:io';

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
}
