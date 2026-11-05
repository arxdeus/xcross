import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_storyboard_reader.dart';
import 'package:xcross/src/shared/apple/launch_screen/storyboardc/binary_plist.dart';
import 'package:xcross/src/shared/apple/launch_screen/storyboardc/nib_archive.dart';
import 'package:xcross/src/shared/apple/launch_screen/storyboardc/storyboardc_templates.dart';

/// A compiled storyboard: file name (relative to the `.storyboardc`
/// directory) to bytes.
@internal
@immutable
final class CompiledStoryboard {
  const CompiledStoryboard(this.files);
  final Map<String, Uint8List> files;
}

/// Generates the `.storyboardc` `ibtool` would produce for the simple launch
/// storyboards xcross understands: a solid background color and at most one
/// centered or aspect-fit image view. Output is byte-identical to Xcode's for
/// the supported shapes (see the tests), so iOS renders exactly the launch
/// screen the storyboard describes.
@internal
final class LaunchStoryboardCompiler {
  const LaunchStoryboardCompiler._();

  /// Default ids Interface Builder gives a launch storyboard's controller
  /// and view. The ids only name the nib files, so any value is valid.
  static const controllerId = '01J-lp-oVM';
  static const viewId = 'Ze5-6b-2t3';

  static const _contentModes = {
    'scaleToFill': 0,
    'scaleAspectFit': 1,
    'scaleAspectFill': 2,
    'redraw': 3,
    'center': 4,
    'top': 5,
    'bottom': 6,
    'left': 7,
    'right': 8,
  };

  /// Whether [spec] can be compiled faithfully.
  static bool canCompile(LaunchScreenSpec spec) =>
      spec.unsupported.isEmpty &&
      spec.backgroundColorName == null &&
      spec.backgroundImageName == null &&
      spec.backgroundColor != null &&
      _supportedColor(spec.backgroundColor!) &&
      (spec.imageName == null ||
          (spec.imageIsCentered &&
              _contentModes.containsKey(spec.imageContentMode)));

  /// Returns null when [spec] is outside the supported shapes.
  static CompiledStoryboard? compile(LaunchScreenSpec spec) {
    if (!canCompile(spec)) return null;
    final color = spec.backgroundColor!;
    final imageName = spec.imageName;
    final template = imageName == null
        ? viewWithoutImageObjects
        : viewWithImageObjects;

    final objects = <NibObject>[];
    for (final o in template) {
      switch (o.className) {
        case 'UIColor':
          objects.add(_color(o, color));
        case 'UIImageView':
          objects.add(_withMode(o, _contentModes[spec.imageContentMode]!));
        case 'NSString' when o.values.first.stringValue == 'LaunchImage':
          objects.add(
            NibObject('NSString', [NibValue.string('NS.bytes', imageName!)]),
          );
        default:
          objects.add(o);
      }
    }
    const viewNib = '$controllerId-view-$viewId';
    return CompiledStoryboard({
      '$viewNib.nib': NibArchiveWriter.write(objects),
      'UIViewController-$controllerId.nib': NibArchiveWriter.write(
        controllerObjects,
      ),
      'Info.plist': BinaryPlist.write({
        'UIViewControllerIdentifiersToNibNames': {
          'UIViewController-$controllerId': 'UIViewController-$controllerId',
        },
        'UIStoryboardDesignatedEntryPointIdentifier':
            'UIViewController-$controllerId',
        'UIStoryboardVersion': 1,
      }),
    });
  }

  static NibObject _withMode(NibObject o, int mode) => o.withValues([
    for (final v in o.values)
      if (v.key == 'UIContentMode') NibValue.int8('UIContentMode', mode) else v,
  ]);

  static String _num(double v) {
    var s = v.toStringAsFixed(3);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  static bool _supportedColor(AssetColor c) =>
      c.colorSpace == AssetColorSpace.srgb ||
      c.colorSpace == AssetColorSpace.grayGamma22;

  static NibObject _color(NibObject template, AssetColor c) {
    if (c.colorSpace == AssetColorSpace.grayGamma22) {
      return template.withValues([
        const NibValue.int8('UIColorComponentCount', 2),
        ..._channel('UIWhite', c.red),
        ..._channel('UIAlpha', c.alpha),
        NibValue.string(
          'NSWhite',
          c.alpha == 1 ? _num(c.red) : '${_num(c.red)} ${_num(c.alpha)}',
        ),
        const NibValue.int8('NSColorSpace', 4),
      ]);
    }
    final rgb = (r: c.red, g: c.green, b: c.blue);
    return template.withValues([
      const NibValue.int8('UIColorComponentCount', 4),
      ..._channel('UIRed', rgb.r),
      ..._channel('UIGreen', rgb.g),
      ..._channel('UIBlue', rgb.b),
      ..._channel('UIAlpha', c.alpha),
      NibValue.string(
        'NSRGB',
        c.alpha == 1
            ? '${_num(rgb.r)} ${_num(rgb.g)} ${_num(rgb.b)}'
            : '${_num(rgb.r)} ${_num(rgb.g)} ${_num(rgb.b)} ${_num(c.alpha)}',
      ),
      const NibValue.int8('NSColorSpace', 2),
    ]);
  }

  static List<NibValue> _channel(String key, double v) {
    final asFloat = _toFloat32(v);
    return [
      NibValue.float(key, asFloat),
      if (asFloat != v) NibValue.double('$key-Double', v),
    ];
  }

  static double _toFloat32(double v) =>
      (ByteData(4)..setFloat32(0, v)).getFloat32(0);
}
