import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_storyboard_reader.dart';
import 'package:xcross/src/shared/apple/launch_screen/storyboardc/binary_plist.dart';
import 'package:xcross/src/shared/apple/launch_screen/storyboardc/launch_storyboard_compiler.dart';
import 'package:xcross/src/shared/apple/launch_screen/storyboardc/nib_archive.dart';

const _view = 'Ze5-6b-2t3.nib';

LaunchScreenSpec _spec({
  AssetColor? color = const AssetColor(red: 1, green: 1, blue: 1),
  String? image = 'LaunchImage',
  String mode = 'center',
  bool centered = true,
  List<String> unsupported = const [],
}) => LaunchScreenSpec(
  backgroundColor: color,
  imageName: image,
  imageIsCentered: centered,
  imageContentMode: mode,
  unsupported: unsupported,
);

bool _contains(Uint8List bytes, String needle) =>
    latin1.decode(bytes).contains(needle);

void main() {
  test('emits the three files ibtool emits', () {
    final out = LaunchStoryboardCompiler.compile(_spec())!;
    expect(out.files.keys, {
      '01J-lp-oVM-view-$_view',
      'UIViewController-01J-lp-oVM.nib',
      'Info.plist',
    });
    final nib = out.files['01J-lp-oVM-view-$_view']!;
    expect(ascii.decode(nib.sublist(0, 10)), 'NIBArchive');
    expect(_contains(nib, 'LaunchImage'), isTrue);
    expect(_contains(nib, 'UIImageView'), isTrue);
    expect(ascii.decode(out.files['Info.plist']!.sublist(0, 8)), 'bplist00');
  });

  test('Info.plist is byte identical to the one ibtool writes', () {
    final bytes = LaunchStoryboardCompiler.compile(
      _spec(),
    )!.files['Info.plist']!;
    expect(
      base64.encode(bytes),
      'YnBsaXN0MDDTAQIDBAcIXxAlVUlWaWV3Q29udHJvbGxlcklkZW50aWZpZXJzVG9OaWJOYW1lc18QKlVJU3Rvcnlib2FyZERlc2lnbmF0ZWRFbnRyeVBvaW50SWRlbnRpZmllcl8QE1VJU3Rvcnlib2FyZFZlcnNpb27RBQZfEBtVSVZpZXdDb250cm9sbGVyLTAxSi1scC1vVk1fEBtVSVZpZXdDb250cm9sbGVyLTAxSi1scC1vVk1fEBtVSVZpZXdDb250cm9sbGVyLTAxSi1scC1vVk0QAQgPN2R6fZu51wAAAAAAAAEBAAAAAAAAAAkAAAAAAAAAAAAAAAAAAADZ',
    );
  });

  test('color and image name are substituted', () {
    final out = LaunchStoryboardCompiler.compile(
      _spec(
        color: const AssetColor(red: 0.2, green: 0.4, blue: 0.6),
        image: 'Splash',
      ),
    )!;
    final nib = out.files['01J-lp-oVM-view-$_view']!;
    expect(_contains(nib, '0.2 0.4 0.6'), isTrue);
    expect(_contains(nib, 'UIRed-Double'), isTrue);
    expect(_contains(nib, 'Splash'), isTrue);
    expect(_contains(nib, 'LaunchImage'), isFalse);
  });

  test('no image variant drops the image view', () {
    final nib = LaunchStoryboardCompiler.compile(
      _spec(image: null),
    )!.files['01J-lp-oVM-view-$_view']!;
    expect(_contains(nib, 'UIImageView'), isFalse);
  });

  test('gray background uses the white components', () {
    final nib = LaunchStoryboardCompiler.compile(
      _spec(color: const AssetColor.gray(0.5)),
    )!.files['01J-lp-oVM-view-$_view']!;
    expect(_contains(nib, 'UIWhite'), isTrue);
    expect(_contains(nib, 'NSRGB'), isFalse);
  });

  test('content mode is encoded', () {
    final center = LaunchStoryboardCompiler.compile(_spec())!;
    final fit = LaunchStoryboardCompiler.compile(
      _spec(mode: 'scaleAspectFit'),
    )!;
    expect(
      center.files['01J-lp-oVM-view-$_view'],
      isNot(fit.files['01J-lp-oVM-view-$_view']),
    );
  });

  test('unsupported shapes are not compiled', () {
    expect(LaunchStoryboardCompiler.compile(_spec(color: null)), isNull);
    expect(
      LaunchStoryboardCompiler.compile(_spec(unsupported: ['label'])),
      isNull,
    );
    expect(LaunchStoryboardCompiler.compile(_spec(centered: false)), isNull);
    expect(
      LaunchStoryboardCompiler.compile(
        _spec(
          color: const AssetColor(
            red: 1,
            green: 1,
            blue: 1,
            colorSpace: AssetColorSpace.displayP3,
          ),
        ),
      ),
      isNull,
    );
  });

  test('NibArchiveWriter header and tables', () {
    final bytes = NibArchiveWriter.write([
      const NibObject('NSObject', [NibValue.int8('A', 1)]),
    ]);
    final data = ByteData.sublistView(bytes);
    expect(data.getUint32(10, Endian.little), 1); // version
    expect(data.getUint32(14, Endian.little), 10); // extension
    expect(data.getUint32(18, Endian.little), 1); // objects
    expect(data.getUint32(22, Endian.little), 50); // objects offset
  });

  test('BinaryPlist writes a bplist00 trailer', () {
    final bytes = BinaryPlist.write({'A': 1});
    expect(ascii.decode(bytes.sublist(0, 8)), 'bplist00');
    expect(bytes.length, greaterThan(40));
  });
}
