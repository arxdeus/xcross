import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';

void main() {
  test(
    'interop search paths remain visible after response-file repair',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'xcross-interop-rsp-',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final include = p.join(
        scratch.path,
        'arm64-apple-ios',
        'debug',
        'A.build',
      );
      final interop = ['-Xcc', '-I', '-Xcc', include];
      final arguments = ['swiftc.exe', ...interop, '-D', 'A' * 29000];
      File(
        p.join(scratch.path, 'debug.yaml'),
      ).writeAsStringSync('    args: ${jsonEncode(arguments)}\n');
      expect(
        GeneratedPluginsPackage.manifestCarriesInteropSearchPaths(
          scratch.path,
          interop,
        ),
        isTrue,
      );
      expect(
        await GeneratedPluginsPackage.repairWindowsSwiftResponseFiles(
          scratch.path,
          windows: true,
        ),
        isTrue,
      );
      expect(
        GeneratedPluginsPackage.manifestCarriesInteropSearchPaths(
          scratch.path,
          interop,
        ),
        isTrue,
      );
    },
  );

  test('counts escaped UTF-16 command line units including executable', () {
    final arguments = [
      r'C:\very long tool directory\clang.exe',
      'quote"value',
      r'ends\',
      '😀',
    ];
    final measured = GeneratedPluginsPackage.windowsCommandLineLength(
      arguments,
    );
    expect(measured, greaterThan(arguments.join(' ').length));
    expect(measured, greaterThan(0));
  });

  test(
    'externalizes long Clang commands without changing Linux plans',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'xcross clang response ',
      );
      addTearDown(() => root.delete(recursive: true));
      final args = ['clang.exe', '-I', r'C:\headers with spaces', 'X' * 29000];
      final plan = File(p.join(root.path, 'debug.yaml'));
      final original = '    args: ${jsonEncode(args)}\n';
      await plan.writeAsString(original);
      expect(
        await GeneratedPluginsPackage.repairWindowsSwiftResponseFiles(
          root.path,
          windows: false,
        ),
        isFalse,
      );
      expect(await plan.readAsString(), original);
      expect(
        await GeneratedPluginsPackage.repairWindowsSwiftResponseFiles(
          root.path,
          windows: true,
        ),
        isTrue,
      );
      final rewritten =
          (jsonDecode((await plan.readAsLines()).single.substring(10)) as List)
              .cast<String>();
      expect(rewritten, hasLength(2));
      final response = await File(rewritten.last.substring(1)).readAsString();
      expect(response, contains(r'"C:\\headers with spaces"'));
    },
  );

  test('Clang accepts the generated response file on Windows', () async {
    if (!Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('xcross clang verify ');
    addTearDown(() => root.delete(recursive: true));
    final source = File(p.join(root.path, 'source file.c'))
      ..writeAsStringSync('int answer(void) { return 42; }\n');
    final output = p.join(root.path, 'output file.obj');
    final args = [
      'clang.exe',
      '-c',
      source.path,
      '-o',
      output,
      '-DLARGE=${'A' * 29000}',
    ];
    final plan = File(p.join(root.path, 'debug.yaml'))
      ..writeAsStringSync('    args: ${jsonEncode(args)}\n');
    expect(
      await GeneratedPluginsPackage.repairWindowsSwiftResponseFiles(
        root.path,
        windows: true,
      ),
      isTrue,
    );
    final rewritten =
        (jsonDecode((await plan.readAsLines()).single.substring(10)) as List)
            .cast<String>();
    final result = await Process.run('clang', rewritten.skip(1).toList());
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(File(output).existsSync(), isTrue);
  });

  test(
    'externalizes long swift argv and preserves short and other tools',
    () async {
      final root = await Directory.systemTemp.createTemp('xcross response ');
      addTearDown(() => root.delete(recursive: true));
      final arguments = [
        r'C:\Swift Tools\swiftc.exe',
        '-D',
        'A' * 29000,
        r'C:\path with spaces\file.swift',
        'quote"value',
        '',
        r'ends\',
      ];
      final short = '    args: ${jsonEncode(['swiftc.exe', '--version'])}';
      final other = '    args: ${jsonEncode(['other.exe', 'A' * 29000])}';
      final plan = File(p.join(root.path, 'debug.yaml'));
      await plan.writeAsString(
        'commands:\n    args: ${jsonEncode(arguments)}\n$short\n$other\n',
      );
      expect(
        await GeneratedPluginsPackage.repairWindowsSwiftResponseFiles(
          root.path,
          windows: false,
        ),
        isFalse,
      );
      expect(
        Directory(p.join(root.path, '.xcross-response')).existsSync(),
        isFalse,
      );
      expect(
        await plan.readAsString(),
        'commands:\n    args: ${jsonEncode(arguments)}\n$short\n$other\n',
      );
      expect(
        await GeneratedPluginsPackage.repairWindowsSwiftResponseFiles(
          root.path,
          windows: true,
        ),
        isTrue,
      );
      final lines = await plan.readAsLines();
      final invocation = (jsonDecode(lines[1].substring(10)) as List)
          .cast<String>();
      expect(invocation.first, arguments.first);
      expect(invocation.length, 2);
      expect(invocation.last.startsWith('@'), isTrue);
      final response = await File(invocation.last.substring(1)).readAsLines();
      expect(response, [
        '"-D"',
        '"${'A' * 29000}"',
        r'"C:\path with spaces\file.swift"',
        r'"quote\"value"',
        '""',
        r'"ends\\"',
      ]);
      expect(lines[2], short);
      expect(lines[3], other);
      final cache = Directory(p.join(root.path, '.xcross-response'));
      final orphan = File(p.join(cache.path, '${'a' * 64}.rsp'))
        ..writeAsStringSync('unused');
      final old = DateTime.now().subtract(const Duration(days: 8));
      orphan.setLastModifiedSync(old);
      File(invocation.last.substring(1)).setLastModifiedSync(old);
      final content = await plan.readAsString();
      expect(
        await GeneratedPluginsPackage.repairWindowsSwiftResponseFiles(
          root.path,
          windows: true,
        ),
        isFalse,
      );
      expect(await plan.readAsString(), content);
      expect(orphan.existsSync(), isFalse);
      expect(File(invocation.last.substring(1)).existsSync(), isTrue);
    },
  );
}
