import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/internal/clang_requirement.dart';

void main() {
  for (final suffix in ['.exe', '.EXE']) {
    test(
      'uses resolved Windows executable suffix $suffix for clang++',
      () async {
        final dir = await Directory.systemTemp.createTemp('xcross-clang-');
        try {
          final executable = '${dir.path}/clang$suffix';
          File(executable).createSync();
          File('${dir.path}/clang++$suffix').createSync();
          expect(
            await ClangRequirement.resolve(
              directories: [dir.path],
              lookup: (name, _) async => name == 'clang' ? executable : null,
              version: (_) async => 'clang version 22.1.8',
            ),
            executable,
          );
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );
  }
  test('parses clang version and rejects unrelated version text', () {
    expect(ClangRequirement.majorVersion('Ubuntu clang version 20.1.2'), 20);
    expect(ClangRequirement.majorVersion('Apple clang version 19.0.0'), 19);
    expect(ClangRequirement.majorVersion('LLVM version 21'), isNull);
  });

  test('finds versioned clang when the default on PATH is too old', () async {
    final dir = await Directory.systemTemp.createTemp('xcross-clang-');
    try {
      for (final name in ['clang-21', 'clang++-21', 'clang-19', 'clang++-19']) {
        File('${dir.path}/$name').createSync();
      }
      final result = await ClangRequirement.resolve(
        directories: [dir.path],
        lookup: (name, _) async => name == 'clang'
            ? '${dir.path}/clang'
            : File('${dir.path}/$name').existsSync()
            ? '${dir.path}/$name'
            : null,
        version: (path) async => path.endsWith('-21')
            ? 'clang version 21.0.0'
            : 'clang version 19.0.0',
      );
      expect(result, '${dir.path}/clang-21');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('rejects old clang and a versioned clang without clang++', () async {
    final dir = await Directory.systemTemp.createTemp('xcross-clang-');
    try {
      File('${dir.path}/clang-20').createSync();
      expect(
        await ClangRequirement.resolve(
          directories: [dir.path],
          lookup: (name, _) async => File('${dir.path}/$name').existsSync()
              ? '${dir.path}/$name'
              : null,
          version: (_) async => 'clang version 20.0.0',
        ),
        isNull,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
