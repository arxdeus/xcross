import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/signing/code_resources.dart';
import 'package:crypto/crypto.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';

import '../support/mapped_apple_fixture.dart';

void main() {
  test(
    'mapped filesystem seals bytes and literal symlink targets deterministically',
    () {
      final fixture = MappedAppleFixture();
      addTearDown(fixture.dispose);
      final resource = fixture.path('resource.bin');
      final localization = fixture.path('en.lproj/Localizable.strings');
      fixture.fileSystem.file(resource).writeAsBytesSync([1, 2, 3]);
      fixture.fileSystem.file(localization).parent.createSync(recursive: true);
      fixture.fileSystem.file(localization).writeAsBytesSync([4, 5, 6]);
      fixture.fileSystem.link(fixture.path('alias')).createSync('resource.bin');
      final builder = CodeResourcesBuilder(hostServices: fixture.services);
      Uint8List build() => builder.build(
        candidates: [
          SealCandidate(
            path: resource,
            relativePath: 'resource.bin',
            isSymlink: false,
          ),
          SealCandidate(
            path: localization,
            relativePath: 'en.lproj/Localizable.strings',
            isSymlink: false,
          ),
          SealCandidate(
            path: fixture.path('alias'),
            relativePath: 'alias',
            isSymlink: true,
          ),
          SealCandidate(
            path: fixture.path('missing'),
            relativePath: '_CodeSignature/CodeResources',
            isSymlink: false,
          ),
          SealCandidate(
            path: fixture.path('missing'),
            relativePath: 'Runner',
            isSymlink: false,
          ),
        ],
        executableRelativePath: 'Runner',
        bundleRelativePath: '.',
        rootPath: fixture.logicalRoot,
      );
      final bytes = build();
      expect(build(), bytes);
      final plist =
          PropertyListSerialization.propertyListWithString(utf8.decode(bytes))
              as Map;
      final files = plist['files'] as Map;
      final files2 = plist['files2'] as Map;
      expect(
        (files['resource.bin'] as ByteData).buffer.asUint8List(),
        sha1.convert([1, 2, 3]).bytes,
      );
      final hashes = files2['resource.bin'] as Map;
      expect(
        (hashes['hash2'] as ByteData).buffer.asUint8List(),
        sha256.convert([1, 2, 3]).bytes,
      );
      expect((files2['alias'] as Map)['symlink'], 'resource.bin');
      expect(
        (files2['en.lproj/Localizable.strings'] as Map)['optional'],
        isTrue,
      );
      expect(File(resource).existsSync(), isFalse);
      expect(Link(fixture.path('alias')).existsSync(), isFalse);
      expect(files.containsKey('_CodeSignature/CodeResources'), isFalse);
    },
  );
}
