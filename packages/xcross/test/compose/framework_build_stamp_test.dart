import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/build/framework_build_stamp.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('xcross_stamp'));
  tearDown(() => root.deleteSync(recursive: true));

  String framework() {
    final path = p.join(root.path, 'ComposeApp.framework');
    Directory(path).createSync(recursive: true);
    return path;
  }

  File input(String name, String contents) => File(p.join(root.path, name))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  test('is not up to date before anything is built', () {
    final klib = input('module.klib', 'a');
    final stamp = FrameworkBuildStamp.forFramework(framework());

    expect(
      stamp.isUpToDate(
        frameworkPath: framework(),
        inputs: [klib.path],
        arguments: const ['-target', 'ios_arm64'],
      ),
      isFalse,
    );
  });

  test('is up to date after writing the same inputs', () {
    final klib = input('module.klib', 'a');
    final path = framework();
    final stamp = FrameworkBuildStamp.forFramework(path);
    const args = ['-target', 'ios_arm64'];

    stamp.write(inputs: [klib.path], arguments: args);

    expect(
      stamp.isUpToDate(
        frameworkPath: path,
        inputs: [klib.path],
        arguments: args,
      ),
      isTrue,
    );
  });

  test('changed input content invalidates the stamp', () {
    final klib = input('module.klib', 'a');
    final path = framework();
    final stamp = FrameworkBuildStamp.forFramework(path);
    const args = ['-target', 'ios_arm64'];
    stamp.write(inputs: [klib.path], arguments: args);

    klib.writeAsStringSync('b');

    expect(
      stamp.isUpToDate(
        frameworkPath: path,
        inputs: [klib.path],
        arguments: args,
      ),
      isFalse,
    );
  });

  test('changed compiler arguments invalidate the stamp', () {
    final klib = input('module.klib', 'a');
    final path = framework();
    final stamp = FrameworkBuildStamp.forFramework(path);
    stamp.write(inputs: [klib.path], arguments: const ['-target', 'ios_arm64']);

    // A configuration or bundle-id switch changes the output without
    // touching a single source file.
    expect(
      stamp.isUpToDate(
        frameworkPath: path,
        inputs: [klib.path],
        arguments: const ['-target', 'ios_arm64', '-opt'],
      ),
      isFalse,
    );
  });

  test('a deleted framework is never up to date', () {
    final klib = input('module.klib', 'a');
    final path = framework();
    final stamp = FrameworkBuildStamp.forFramework(path);
    const args = ['-target', 'ios_arm64'];
    stamp.write(inputs: [klib.path], arguments: args);

    Directory(path).deleteSync(recursive: true);

    expect(
      stamp.isUpToDate(
        frameworkPath: path,
        inputs: [klib.path],
        arguments: args,
      ),
      isFalse,
    );
  });

  test('a missing input is never up to date', () {
    final klib = input('module.klib', 'a');
    final path = framework();
    final stamp = FrameworkBuildStamp.forFramework(path);
    const args = ['-target', 'ios_arm64'];
    stamp.write(inputs: [klib.path], arguments: args);

    klib.deleteSync();

    expect(
      stamp.isUpToDate(
        frameworkPath: path,
        inputs: [klib.path],
        arguments: args,
      ),
      isFalse,
    );
  });

  test('invalidate forces the next build', () {
    final klib = input('module.klib', 'a');
    final path = framework();
    final stamp = FrameworkBuildStamp.forFramework(path);
    const args = ['-target', 'ios_arm64'];
    stamp.write(inputs: [klib.path], arguments: args);

    stamp.invalidate();

    expect(
      stamp.isUpToDate(
        frameworkPath: path,
        inputs: [klib.path],
        arguments: args,
      ),
      isFalse,
    );
  });

  test('a changed file inside a directory input invalidates the stamp', () {
    // Dependency klibs can be unpacked directories, where the path itself
    // never changes but its contents do.
    final dir = Directory(p.join(root.path, 'dep.klib'))
      ..createSync(recursive: true);
    final inner = File(p.join(dir.path, 'linkdata', 'module'))
      ..createSync(recursive: true)
      ..writeAsStringSync('one');
    final path = framework();
    final stamp = FrameworkBuildStamp.forFramework(path);
    const args = ['-target', 'ios_arm64'];
    stamp.write(inputs: [dir.path], arguments: args);
    expect(
      stamp.isUpToDate(
        frameworkPath: path,
        inputs: [dir.path],
        arguments: args,
      ),
      isTrue,
    );

    inner.writeAsStringSync('two');

    expect(
      stamp.isUpToDate(
        frameworkPath: path,
        inputs: [dir.path],
        arguments: args,
      ),
      isFalse,
    );
  });

  test('input order does not affect the stamp', () {
    final a = input('a.klib', 'a');
    final b = input('b.klib', 'b');
    final path = framework();
    final stamp = FrameworkBuildStamp.forFramework(path);
    const args = ['-target', 'ios_arm64'];
    stamp.write(inputs: [a.path, b.path], arguments: args);

    expect(
      stamp.isUpToDate(
        frameworkPath: path,
        inputs: [b.path, a.path],
        arguments: args,
      ),
      isTrue,
    );
  });
}
