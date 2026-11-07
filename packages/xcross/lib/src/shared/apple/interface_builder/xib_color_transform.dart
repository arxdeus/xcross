import 'package:meta/meta.dart';

import 'package:xcross/src/shared/apple/interface_builder/xib_float32.dart';

/// Reproduces how `ibtool` turns a `calibratedRGB` (Generic RGB) or
/// `displayP3` color into the extended sRGB components it archives.
///
/// Interface Builder first converts a non sRGB color to Display P3
/// (`-[NSColor colorUsingColorSpace:]`) and then runs a
/// `CGColorTransform` to extended sRGB. Both hops are executed by vImage
/// in single precision: a symmetric piecewise gamma per channel
/// (`vImageSymmetricPiecewiseGamma_PlanarF`, whose `pow` is a NEON
/// log2/exp2 polynomial), a 3x3 matrix, and the inverse gamma. The
/// constants below are the single precision parameters ColorSync reports
/// for those conversions.
@internal
final class XibColorTransform {
  const XibColorTransform._();

  /// Generic RGB (gamma 1.8) components to extended sRGB.
  static List<double> genericRgbToSrgb(double r, double g, double b) {
    final p3 = _convert(
      [f32(r), f32(g), f32(b)],
      _genericDecode,
      _genericToP3,
      _srgbEncode,
    );
    return displayP3ToSrgb(p3[0], p3[1], p3[2]);
  }

  /// Display P3 components to extended sRGB.
  static List<double> displayP3ToSrgb(double r, double g, double b) =>
      _convert([f32(r), f32(g), f32(b)], _srgbDecode, _p3ToSrgb, _srgbEncode);

  static List<double> _convert(
    List<double> input,
    XibGammaCurve decode,
    List<int> matrix,
    XibGammaCurve encode,
  ) {
    final linear = [for (final c in input) decode.apply(c)];
    final m = [for (final bits in matrix) f32FromBits(bits)];
    return [
      for (var row = 0; row < 3; row++)
        encode.apply(
          fmaf(
            m[row * 3 + 2],
            linear[2],
            fmaf(linear[0], m[row * 3], f32(m[row * 3 + 1] * linear[1])),
          ),
        ),
    ];
  }

  static const _genericDecode = XibGammaCurve(
    gamma: 0x3fe66666,
    exp0: 0x3f800000,
    exp1: 0,
    exp2: 0,
    lin0: 0x3d800000,
    boundary: 0x3d000000,
  );
  static const _srgbDecode = XibGammaCurve(
    gamma: 0x4019999a,
    exp0: 0x3f72a76e,
    exp1: 0x3d558919,
    exp2: 0,
    lin0: 0x3d9e8391,
    boundary: 0x3d25aee6,
  );
  static const _srgbEncode = XibGammaCurve(
    gamma: 0x3ed55555,
    exp0: 0x3f918d1e,
    exp1: 0,
    exp2: 0xbd6147ae,
    lin0: 0x414eb852,
    boundary: 0x3b4d2e31,
  );
  static const _genericToP3 = [
    0x3f58bcc0, 0x3e16028e, 0x3be14d7f, //
    0x3d585488, 0x3f6a6824, 0x3d01293c, //
    0x3c8dc2bc, 0x3d88e9f9, 0x3f6a74ab,
  ];
  static const _p3ToSrgb = [
    0x3f9ccce4, 0xbe665ffc, 0xb7e472d2, //
    0xbd2c68e3, 0x3f856293, 0x37b40ef7, //
    0xbca0c46f, 0xbda0fe41, 0x3f8c92f6,
  ];
}

/// One `vImageSymmetricPiecewiseGamma_PlanarF` curve, parameters as single
/// precision bit patterns.
@internal
@immutable
final class XibGammaCurve {
  const XibGammaCurve({
    required this.gamma,
    required this.exp0,
    required this.exp1,
    required this.exp2,
    required this.lin0,
    required this.boundary,
  });

  final int gamma;
  final int exp0;
  final int exp1;
  final int exp2;
  final int lin0;
  final int boundary;

  double apply(double x) {
    final y = x.abs();
    final useExp = y >= f32FromBits(boundary);
    final t = useExp
        ? fmaf(y, f32FromBits(exp0), f32FromBits(exp1))
        : fmaf(y, f32FromBits(lin0), 0);
    var r = t;
    if (useExp) {
      r = fmaf(pow(t, f32FromBits(gamma)), 1, f32FromBits(exp2));
    }
    if (!(r > 0)) r = 0;
    return x.isNegative ? -r : r;
  }

  /// vImage's single precision `pow`: log2 via a split polynomial, then
  /// exp2 via a polynomial on the fractional part.
  static double pow(double t, double g) {
    final tb = f32Bits(t);
    final mant = f32FromBits((tb & 0x007fffff) | 0x3f800000);
    final big = mant >= f32FromBits(0x3fb504f3);
    final e = (tb.toSigned(32) >> 23) + (big ? 1 : 0) - 127;
    final f = fmaf(big ? 0.5 : 1.0, mant, -1);
    final f2 = f32(f * f);
    double k(int small, int large) => f32FromBits(big ? large : small);
    final p29 = fmaf(k(0x3d8c36cf, 0x3f126e04), f2, k(0x3e8c16d1, 0x3ea80bd4));
    final p23 = fmaf(k(0x3e383a67, 0x3d7a7ec7), f2, k(0x3eb7a5bf, 0x3eb66ff3));
    final p24 = fmaf(p29, f2, k(0x3ef62766, 0x3ef6559b));
    final p21 = fmaf(p23, f2, k(0x3f38aa06, 0x3f38a9f3));
    var q = fmaf(p24, f2, f32FromBits(0x3fb8aa3b));
    q = fmaf(-p21, f, q);
    final l = f32(f32(f * q) + e.toDouble());
    final yy = f32(l * g);
    final fl = yy.floorToDouble();
    final fr = f32(yy - fl);
    double sc;
    if (f32FromBits(0xc2fc0000) > yy) {
      sc = 0;
    } else if (yy >= 128) {
      sc = double.infinity;
    } else {
      sc = f32FromBits(((fl.toInt() << 23) + 0x3f800000) & 0xffffffff);
    }
    var p = fmaf(f32FromBits(0x395a873d), fr, f32FromBits(0x3aa648ee));
    p = fmaf(p, fr, f32FromBits(0x3c1e264e));
    p = fmaf(p, fr, f32FromBits(0x3d634f9d));
    p = fmaf(p, fr, f32FromBits(0x3e75fe20));
    p = fmaf(p, fr, f32FromBits(0x3f317218));
    final qq = f32(fr * p);
    return fmaf(qq, sc, sc);
  }
}
