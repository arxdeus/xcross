import 'dart:math' as math;

import 'package:meta/meta.dart';

/// A view of the document, as far as constraint ordering needs it.
@internal
final class XibLayoutItem {
  XibLayoutItem(this.id, this.x, this.y, this.width, this.height, this.parent);

  final String id;
  final double x;
  final double y;
  final double width;
  final double height;
  final XibLayoutItem? parent;

  /// Number of superviews (`IBLayoutConstraintViewHierarchyDepthOfView`).
  int get depth {
    var d = 0;
    for (var v = parent; v != null; v = v.parent) {
      d++;
    }
    return d;
  }

  /// True when this item is a strict descendant of [other].
  bool isDescendantOf(XibLayoutItem? other) {
    if (other == null) return false;
    for (var v = parent; v != null; v = v.parent) {
      if (identical(v, other)) return true;
    }
    return false;
  }

  /// This item's frame in the coordinate space of its ancestor [space].
  List<double> rectIn(XibLayoutItem space) {
    if (identical(this, space)) return [0, 0, width, height];
    var ox = 0.0;
    var oy = 0.0;
    XibLayoutItem? v = this;
    while (!identical(v, space)) {
      ox += v!.x;
      oy += v.y;
      v = v.parent;
      if (v == null) throw StateError('$space is not an ancestor of $id');
    }
    return [ox, oy, width, height];
  }

  static XibLayoutItem? sharedAncestor(XibLayoutItem? a, XibLayoutItem? b) {
    if (a == null || b == null) return null;
    if (identical(a, b)) return a;
    final chain = <XibLayoutItem>[];
    for (XibLayoutItem? v = a; v != null; v = v.parent) {
      chain.add(v);
    }
    for (XibLayoutItem? v = b; v != null; v = v.parent) {
      if (chain.any((c) => identical(c, v))) return v;
    }
    return null;
  }
}

/// A `<constraint>`, as far as ordering needs it. Attributes use the
/// `NSLayoutAttribute` numbering.
@internal
final class XibOrderedConstraint {
  XibOrderedConstraint({
    required this.id,
    required this.first,
    required this.firstAttribute,
    required this.second,
    required this.secondAttribute,
    required this.constant,
    required this.priority,
    required this.relation,
  });

  final String id;
  final XibLayoutItem first;
  final int firstAttribute;
  final XibLayoutItem? second;
  final int secondAttribute;
  final double constant;
  final double priority;
  final int relation;
}

/// Sorts the constraints a view owns the way Interface Builder archives
/// them: `-[NSView(IBViewIntegration) ibConstraintComparatorForDocument:]`
/// around `-[IBLayoutConstraint compare:withUserInterfaceLayoutDirection:]`,
/// applied with a stable merge sort.
@internal
final class XibConstraintOrder {
  const XibConstraintOrder._();

  static List<XibOrderedConstraint> sort(
    List<XibOrderedConstraint> constraints,
    XibLayoutItem container,
  ) => _mergeSort(constraints, (a, b) => _outer(a, b, container));

  static List<T> _mergeSort<T>(List<T> list, int Function(T, T) cmp) {
    if (list.length <= 1) return list;
    final mid = list.length ~/ 2;
    final a = _mergeSort(list.sublist(0, mid), cmp);
    final b = _mergeSort(list.sublist(mid), cmp);
    final out = <T>[];
    var i = 0;
    var j = 0;
    while (i < a.length && j < b.length) {
      if (cmp(b[j], a[i]) < 0) {
        out.add(b[j++]);
      } else {
        out.add(a[i++]);
      }
    }
    return out
      ..addAll(a.sublist(i))
      ..addAll(b.sublist(j));
  }

  static int _cmpNum(num a, num b) => a < b ? -1 : (a > b ? 1 : 0);

  static int _cmpId(String a, String b) => a.compareTo(b).sign;

  static XibLayoutItem _item(XibOrderedConstraint c, XibLayoutItem container) =>
      c.second != null && identical(c.first, container) ? c.second! : c.first;

  static int _outer(
    XibOrderedConstraint a,
    XibOrderedConstraint b,
    XibLayoutItem container,
  ) {
    final i1 = _item(a, container);
    final i2 = _item(b, container);
    if (identical(i1, i2)) {
      final r = _compare(a, b);
      return r != 0 ? r : _cmpId(a.id, b.id);
    }
    if (identical(i1, container)) return -1;
    if (identical(i2, container)) return 1;
    final s = XibLayoutItem.sharedAncestor(i1, i2)!;
    final p1 = i1.rectIn(s);
    final p2 = i2.rectIn(s);
    if (p1[0] == p2[0] && p1[1] == p2[1]) return _cmpId(i1.id, i2.id);
    final d1 = _hypot(p1[0], p1[1]);
    final d2 = _hypot(p2[0], p2[1]);
    if (d1 < d2) return -1;
    if (d1 > d2) return 1;
    return p1[0] < p2[0] ? -1 : 1;
  }

  static double _hypot(double x, double y) => math.sqrt(x * x + y * y);

  // IBOrderedLayoutAttributeForLayoutAttribute.
  static const _ordered = [
    6, 5, 17, 16, 10, 9, 11, 20, 2, 13, 19, 18, 4, 3, 14, 15, 8, 7, 1, 12, //
  ];
  static int _ord(int a) => a >= 1 && a <= 20 ? _ordered[a - 1] : 0;

  static const _vertical = {3, 4, 8, 10, 11, 12, 15, 16, 20};
  static const _center = {9, 10, 19, 20};
  static const _size = {7, 8};

  static double _scoringType(XibOrderedConstraint c) {
    final f = c.first;
    final s = c.second;
    if (f.isDescendantOf(s) || (s != null && s.isDescendantOf(f))) {
      return _center.contains(c.firstAttribute) ||
              _center.contains(c.secondAttribute)
          ? 22
          : 23;
    }
    if (f.parent == null || s == null || !identical(f.parent, s.parent)) {
      return s == null ? 23.5 : 20;
    }
    if (c.firstAttribute == c.secondAttribute &&
        _size.contains(c.firstAttribute)) {
      return 26;
    }
    return 24;
  }

  static List<num> _score(XibOrderedConstraint c) {
    final d1 = c.first.depth;
    final d = c.second == null ? d1 : math.max(d1, c.second!.depth);
    // `-depth` compared as an unsigned 64 bit integer.
    final depthKey = d == 0 ? -1 : (1 << 52) - d;
    final relationKey = switch (c.relation) {
      0 => 2,
      1 => 1,
      _ => 0,
    };
    return [
      _scoringType(c).truncate(),
      depthKey,
      _ord(c.firstAttribute),
      _ord(c.secondAttribute),
      c.priority,
      relationKey,
    ];
  }

  static int _compare(XibOrderedConstraint a, XibOrderedConstraint b) {
    final sa = _score(a);
    final sb = _score(b);
    for (var i = 0; i < sa.length; i++) {
      final r = _cmpNum(sa[i], sb[i]);
      if (r != 0) return r;
    }
    return _geometricCompare(a, b);
  }

  static XibLayoutItem? _suggested(XibOrderedConstraint c) => c.second == null
      ? c.first
      : XibLayoutItem.sharedAncestor(c.first, c.second);

  static double _roundHalfAway(double x) =>
      (x.abs() + 0.5).floorToDouble() * (x >= 0 ? 1 : -1);

  static double _attributeValue(int a, List<double> r) => switch (a) {
    1 || 5 => r[0],
    2 || 6 => r[0] + r[2],
    3 => r[1],
    4 => r[1] + r[3],
    7 => r[2],
    8 => r[3],
    9 => r[0] + r[2] / 2,
    10 => r[1] + r[3] / 2,
    _ => throw UnsupportedError('layout attribute $a'),
  };

  /// The line IB draws for the constraint, plus a tie breaker.
  static (List<double>, double) _geometry(
    XibOrderedConstraint c,
    XibLayoutItem space,
  ) {
    if (c.second == null) {
      final r = c.first.rectIn(space);
      final x = r[0];
      final y = r[1];
      final w = r[2];
      final h = r[3];
      if (c.firstAttribute == 7) return ([x, y + h, x + w, y + h], 0);
      if (c.firstAttribute == 8) return ([x + w, y + h, x + w, y], 0);
      throw UnsupportedError('absolute attribute ${c.firstAttribute}');
    }
    final r1 = c.first.rectIn(space);
    final r2 = c.second!.rectIn(space);
    final a1 = c.firstAttribute;
    var a2 = c.secondAttribute;
    if (_vertical.contains(a1) != _vertical.contains(a2)) a2 = a1;
    final v1 = _attributeValue(a1, r1);
    final v2 = _attributeValue(a2, r2);
    var pa = v1.floorToDouble();
    var pb = v2.floorToDouble();
    if (_center.contains(c.firstAttribute) ||
        _center.contains(c.secondAttribute)) {
      if (c.constant == 0) {
        pa = pb = math.min(_roundHalfAway(v1), _roundHalfAway(v2));
      } else if (c.first.isDescendantOf(c.second)) {
        pb = pa;
      } else if (c.second!.isDescendantOf(c.first)) {
        pa = pb;
      }
    }
    if (pa - pb == 0) {
      final r = c.second!.isDescendantOf(c.first) ? r2 : r1;
      if (!_vertical.contains(a1)) {
        final lo = math.min(r1[1], r2[1]);
        final hi = math.max(r1[1] + r1[3], r2[1] + r2[3]);
        return ([pa, hi, pa, lo], r[1]);
      }
      final lo = math.min(r1[0], r2[0]);
      final hi = math.max(r1[0] + r1[2], r2[0] + r2[2]);
      return ([lo, pa, hi, pa], r[0]);
    }
    double mid;
    if (_vertical.contains(a1)) {
      final w1 = _roundHalfAway(r1[2] / 0.1) * 0.1;
      final w2 = _roundHalfAway(r2[2] / 0.1) * 0.1;
      final rr = w1 > w2 ? r2 : r1;
      mid = rr[0] + rr[2] / 2;
    } else {
      final rr = r1[3] > r2[3] ? r2 : r1;
      mid = rr[1] + rr[3] / 2;
    }
    final p1 = _vertical.contains(a1) ? [mid, pa] : [pa, mid];
    final p2 = _vertical.contains(a2) ? [mid, pb] : [pb, mid];
    return ([p1[0], p1[1], p2[0], p2[1]], 0);
  }

  static int _geometricCompare(XibOrderedConstraint a, XibOrderedConstraint b) {
    final space = XibLayoutItem.sharedAncestor(_suggested(a), _suggested(b));
    if (space == null) return 0;
    final (la, ea) = _geometry(a, space);
    final (lb, eb) = _geometry(b, space);
    double length(List<double> l) => _hypot(l[0] - l[2], l[1] - l[3]);
    double toCorner(List<double> l) =>
        _hypot(math.min(l[0], l[2]), math.min(l[1], l[3]));
    var r = _cmpNum(length(la), length(lb));
    if (r == 0) r = _cmpNum(toCorner(la), toCorner(lb));
    if (r == 0) r = _cmpNum(ea, eb);
    return -r;
  }
}
