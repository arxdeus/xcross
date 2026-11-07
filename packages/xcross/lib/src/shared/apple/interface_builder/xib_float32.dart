import 'dart:typed_data';

import 'package:meta/meta.dart';

final Float32List _f32 = Float32List(1);
final Uint32List _u32 = _f32.buffer.asUint32List();
final Float64List _f64 = Float64List(1);
final Uint64List _u64 = _f64.buffer.asUint64List();

/// Rounds [x] to the nearest IEEE single precision value.
@internal
double f32(double x) {
  _f32[0] = x;
  return _f32[0];
}

/// The bit pattern of [x] as a single precision float.
@internal
int f32Bits(double x) {
  _f32[0] = x;
  return _u32[0];
}

/// The single precision float with bit pattern [bits].
@internal
double f32FromBits(int bits) {
  _u32[0] = bits & 0xffffffff;
  return _f32[0];
}

/// Single precision fused multiply add: `a * b + c` with one rounding, as
/// the ARM `fmadd`/`fmla` instructions compute it.
@internal
double fmaf(double a, double b, double c) {
  // a and b are singles, so the product is exact in a double.
  final p = a * b;
  final s = p + c;
  // Error of the double addition (TwoSum).
  final bb = s - p;
  final err = (p - (s - bb)) + (c - bb);
  final r = f32(s);
  if (err == 0 || !_isSingleMidpoint(s)) return r;
  // `s` sits exactly between two singles only because of the double
  // rounding; the true sum is on the side of `err`.
  final other = err > 0 ? _nextUp(r, s) : _nextDown(r, s);
  return other;
}

bool _isSingleMidpoint(double s) {
  _f64[0] = s;
  final bits = _u64[0];
  // A double is halfway between two singles when the 29 bits below single
  // precision are exactly 1000...0.
  return (bits & 0x1fffffff) == 0x10000000;
}

double _nextUp(double r, double s) {
  // The rounded single r is one of the two neighbours of s; pick the one
  // above s.
  if (r > s) return r;
  return _step(r, 1);
}

double _nextDown(double r, double s) {
  if (r < s) return r;
  return _step(r, -1);
}

double _step(double r, int direction) {
  final bits = f32Bits(r);
  final positive = (bits & 0x80000000) == 0;
  final up = direction > 0;
  if (r == 0) return f32FromBits(up ? 1 : 0x80000001);
  return f32FromBits(positive == up ? bits + 1 : bits - 1);
}
