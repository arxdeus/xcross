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
}
