import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_target.dart';

void main() {
  const checksum =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  test('discovers only eligible direct literal targets', () {
    const source = '''
let targets: [Target] = [
  .binaryTarget(
    name: "Good",
    url: "https://example.invalid/Good.zip",
    checksum: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ),
  .binaryTarget(name: dynamicName, url: makeURL(), checksum: checksum),
]
''';

    final targets = SwiftPmBinaryTargetManifest.discover(source);
    expect(targets, hasLength(1));
    expect(targets.single.name, 'Good');
    expect(targets.single.url.path, '/Good.zip');
    expect(
      source.substring(targets.single.start, targets.single.end),
      startsWith('.binaryTarget('),
    );
  });

  test('ignores binaryTarget text in comments and Swift strings', () {
    const source = r'''
// .binaryTarget(name: "Comment", url: "https://x/Comment.zip", checksum: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
let text = #".binaryTarget(name: \"Raw\", url: \"https://x/Raw.zip\", checksum: \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\")"#
let multiline = """
.binaryTarget(name: "Multiline", url: "https://x/Multiline.zip", checksum: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
"""
/* outer /* nested */ .binaryTarget(name: "Block", url: "https://x/Block.zip", checksum: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") */
''';
    expect(SwiftPmBinaryTargetManifest.discover(source), isEmpty);
  });

  test('decodes escaped, raw, and multiline direct literals', () {
    const source = r'''
.binaryTarget(name: "Escaped \"Name\"", url: #"https://example.invalid/Escaped.zip"#, checksum: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
.binaryTarget(
  name: """
Multi
""",
  url: """
https://example.invalid/Multi.zip
""",
  checksum: """
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"""
)
''';
    final targets = SwiftPmBinaryTargetManifest.discover(source);
    expect(targets.map((target) => target.name), ['Escaped "Name"', 'Multi']);
  });

  test('raw escaped delimiters do not expose code', () {
    const source = r'''
let text = #"prefix \#" .binaryTarget(name: "Hidden", url: "https://x/Hidden.zip", checksum: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")"#
''';
    expect(SwiftPmBinaryTargetManifest.discover(source), isEmpty);
  });

  test('rejects raw escapes rather than changing evaluated values', () {
    const source = r'''
.binaryTarget(name: #"Changed\#nValue"#, url: "https://x/Raw.zip", checksum: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
''';
    expect(SwiftPmBinaryTargetManifest.discover(source), isEmpty);
  });

  test('rejects indented multiline literals', () {
    const source =
        '''
.binaryTarget(
  name: """
    Indented
    """,
  url: "https://x/Indented.zip",
  checksum: "$checksum"
)
''';
    expect(SwiftPmBinaryTargetManifest.discover(source), isEmpty);
  });

  test('rejects computed, interpolated, and ineligible values', () {
    const source =
        '''
.binaryTarget(name: "Computed", url: makeURL(), checksum: "$checksum")
.binaryTarget(name: "Interpolated \\(value)", url: "https://x/I.zip", checksum: "$checksum")
.binaryTarget(name: "NotZip", url: "https://x/file.tar.gz", checksum: "$checksum")
.binaryTarget(name: "UserInfo", url: "https://user@x/File.zip", checksum: "$checksum")
.binaryTarget(name: "Hostless", url: "https:/Artifact.zip", checksum: "$checksum")
.binaryTarget(name: "BadChecksum", url: "https://x/File.zip", checksum: "abc")
.binaryTarget(name: "BadScheme", url: "file:///tmp/File.zip", checksum: "$checksum")
''';
    expect(SwiftPmBinaryTargetManifest.discover(source), isEmpty);
  });

  test('rewrites matched calls from the end without touching neighbors', () {
    const source =
        'targets: [.binaryTarget(name: "A", url: "https://x/A.zip", checksum: "$checksum"), .target(name: "Keep"), .binaryTarget(name: "B", url: "https://x/B.zip", checksum: "$checksum")]';
    final targets = SwiftPmBinaryTargetManifest.discover(source);
    final rewritten = SwiftPmBinaryTargetManifest.rewriteToLocalPaths(source, {
      targets.first: 'xcross-artifacts/A "quoted".xcframework',
      targets.last: 'xcross-artifacts/B.xcframework',
    });
    expect(
      rewritten,
      contains(
        r'.binaryTarget(name: "A", path: "xcross-artifacts/A \"quoted\".xcframework")',
      ),
    );
    expect(rewritten, contains('.target(name: "Keep")'));
    expect(
      rewritten,
      endsWith(
        '.binaryTarget(name: "B", path: "xcross-artifacts/B.xcframework")]',
      ),
    );
  });

  test('rejects rewrite targets that do not belong to the source', () {
    const first =
        '.binaryTarget(name: "A", url: "https://x/A.zip", checksum: "$checksum")';
    const second =
        '.binaryTarget(name: "B", url: "https://x/B.zip", checksum: "$checksum")';
    final foreignTarget = SwiftPmBinaryTargetManifest.discover(second).single;

    expect(
      () => SwiftPmBinaryTargetManifest.rewriteToLocalPaths(first, {
        foreignTarget: 'A.xcframework',
      }),
      throwsArgumentError,
    );
  });
}
