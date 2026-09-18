// Takes a real Xcode iPhoneOS SDK, injects the arm64e.x1 slices an Xcode 27
// SDK ships, runs xcross's install-path rewrite over it, and links a real
// Objective-C object against the result with the ld64.lld on PATH.
//
// macOS-only and skipped without Xcode + ld64.lld: it is the acceptance check
// behind the unit tests, not a portable one.
@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/sdk_command.dart';

const _sdkRoot =
    '/Applications/Xcode.app/Contents/Developer/Platforms/'
    'iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk';

const _bundleSdk =
    'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_tbd_link-');
  });

  tearDown(() => tmp.delete(recursive: true));

  /// The host's real iOS SDK, or null when this machine has no Xcode.
  String? hostSdk() => Directory(_sdkRoot).existsSync() ? _sdkRoot : null;

  Future<String?> linkerPath() async {
    for (final candidate in [
      '/opt/homebrew/opt/lld/bin/ld64.lld',
      '/usr/local/opt/lld/bin/ld64.lld',
      '/opt/homebrew/bin/ld64.lld',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    final which = await Process.run('which', ['ld64.lld']);
    final path = '${which.stdout}'.trim();
    return path.isEmpty ? null : path;
  }

  test(
    'an SDK carrying arm64e.x1 links after the install-path rewrite',
    () async {
      final linker = await linkerPath();
      final sdkRoot = hostSdk();
      if (linker == null || sdkRoot == null) {
        markTestSkipped('needs Xcode and ld64.lld');
        return;
      }

      // Every .tbd of the real SDK, with arm64e.x1 injected beside arm64e
      // exactly as an Xcode 27 SDK declares it, fed through the same entry
      // writer `xcross sdk install` uses.
      final inject = RegExp(r'(arm64e-ios)(?=[\s,\]])');
      final entries = <CpioEntry>[];
      var injected = 0;
      for (final entity in Directory(sdkRoot).listSync(recursive: true)) {
        if (entity is! File || p.extension(entity.path) != '.tbd') continue;
        final relative = p.relative(entity.path, from: sdkRoot);
        final text = entity.readAsStringSync();
        final withX1 = text.replaceAllMapped(
          inject,
          (m) => '${m.group(1)}, arm64e.x1-ios',
        );
        if (withX1 != text) injected++;
        entries.add(
          CpioEntry(
            name: 'Xcode.app/Contents/$_bundleSdk/$relative',
            mode: 0x81a4,
            data: Uint8List.fromList(utf8.encode(withX1)),
          ),
        );
      }
      expect(
        injected,
        greaterThan(100),
        reason: 'the fixture must actually carry the new architecture',
      );

      await SdkInstall.writeSdkEntries(Stream.fromIterable(entries), tmp.path);

      final sysroot = p.join(tmp.path, p.joinAll(_bundleSdk.split('/')));
      final objectPath = p.join(tmp.path, 'probe.o');
      final source = File(p.join(tmp.path, 'probe.m'));
      await source.writeAsString(
        '@import Foundation;\n'
        'int probe(void) {\n'
        '  @autoreleasepool {\n'
        '    NSString *s = [NSString stringWithUTF8String:"xcross"];\n'
        '    return (int)[s length];\n'
        '  }\n'
        '}\n',
      );

      final compile = await Process.run('xcrun', [
        'clang',
        '-c',
        '-arch',
        'arm64',
        '-target',
        'arm64-apple-ios15.0',
        '-fmodules',
        '-isysroot',
        sdkRoot,
        source.path,
        '-o',
        objectPath,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');

      final link = await Process.run(linker, [
        '-arch',
        'arm64',
        '-platform_version',
        'ios',
        '15.0',
        '18.0',
        '-syslibroot',
        sysroot,
        '-dylib',
        '-lSystem',
        '-F',
        p.join(sysroot, 'System', 'Library', 'Frameworks'),
        '-framework',
        'Foundation',
        '-framework',
        'UIKit',
        objectPath,
        '-o',
        p.join(tmp.path, 'probe.dylib'),
      ]);

      final output = '${link.stdout}\n${link.stderr}';
      expect(
        link.exitCode,
        0,
        reason: 'link against the rewritten SDK failed:\n$output',
      );
      expect(TbdLinkerDiagnostic.reportsUnknownArchitecture(output), isFalse);
      expect(File(p.join(tmp.path, 'probe.dylib')).existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'the same SDK without the rewrite is what the bug report shows',
    () async {
      final linker = await linkerPath();
      if (linker == null) {
        markTestSkipped('no ld64.lld on PATH');
        return;
      }

      // Control: the rewrite is the only difference between this and the test
      // above, so a passing link there cannot be explained by anything else.
      final sysroot = Directory(p.join(tmp.path, 'sdk', 'usr', 'lib'));
      await sysroot.create(recursive: true);
      await File(p.join(sysroot.path, 'libSystem.tbd')).writeAsString(
        '--- !tapi-tbd\n'
        'tbd-version:     4\n'
        'targets:         [ arm64e-ios, arm64e.x1-ios ]\n'
        "install-name:    '/usr/lib/libSystem.dylib'\n"
        // The document terminator matters: without it the reader stops at
        // "unsupported file type" and never reaches the architecture, which
        // would make this control pass for the wrong reason.
        '...\n',
      );

      final link = await Process.run(linker, [
        '-arch',
        'arm64',
        '-platform_version',
        'ios',
        '15.0',
        '18.0',
        '-syslibroot',
        p.join(tmp.path, 'sdk'),
        '-dylib',
        '-lSystem',
        '-o',
        p.join(tmp.path, 'out.dylib'),
      ]);

      final output = '${link.stdout}\n${link.stderr}';
      expect(link.exitCode, isNot(0));
      expect(TbdLinkerDiagnostic.reportsUnknownArchitecture(output), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
