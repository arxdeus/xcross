import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:xcross/src/shared/apple/interface_builder/xib_color_transform.dart';
import 'package:xcross/src/shared/apple/interface_builder/xib_constraint_order.dart';
import 'package:xcross/src/shared/apple/interface_builder/xib_float32.dart';
import 'package:xcross/src/shared/apple/interface_builder/xib_graph.dart';
import 'package:xcross/src/shared/apple/launch_screen/storyboardc/nib_archive.dart';
import 'package:xml/xml.dart';

/// Thrown internally when the document uses something the compiler cannot
/// reproduce byte for byte.
@internal
final class XibUnsupported implements Exception {
  const XibUnsupported(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// A parsed view of the document.
@internal
final class XibView {
  XibView(this.element, this.item, this.parent);

  final XmlElement element;
  final XibLayoutItem item;
  final XibView? parent;
  final List<XibView> subviews = [];
  late final XibNode node;

  String get id => item.id;
  String get tag => element.name.local;
}

/// Turns a `.xib` document into the object graph `ibtool --compile`
/// archives. One instance compiles one document.
@internal
final class XibNibBuilder {
  XibNibBuilder(this.document, this.module);

  final XmlDocument document;
  final String module;
  final XibValuePool pool = XibValuePool();

  final Map<String, XibView> _views = {};
  final Map<String, XibNode> _placeholders = {};
  final Set<String> _constrainedIds = {};
  final Map<String, XmlElement> _systemColors = {};
  final List<XibView> _topViews = [];
  bool _usesUIKitEncoder = false;

  static const _documentAttributes = {
    'type',
    'version',
    'toolsVersion',
    'targetRuntime',
    'propertyAccessControl',
    'useAutolayout',
    'useTraitCollections',
    'useSafeAreas',
    'colorMatched',
  };

  static const _viewTags = {
    'view',
    'label',
    'button',
    'imageView',
    'stackView',
  };

  Uint8List build() {
    final root = document.rootElement;
    if (root.name.local != 'document' ||
        root.getAttribute('type') !=
            'com.apple.InterfaceBuilder3.CocoaTouch.XIB') {
      throw const XibUnsupported('not an iOS .xib document');
    }
    for (final a in root.attributes) {
      if (!_documentAttributes.contains(a.name.local)) {
        throw XibUnsupported('document attribute ${a.name.local}');
      }
    }
    if (root.getAttribute('useAutolayout') != 'YES') {
      throw const XibUnsupported('document without useAutolayout="YES"');
    }
    XmlElement? objects;
    for (final child in root.childElements) {
      switch (child.name.local) {
        case 'device' || 'dependencies':
          break;
        case 'objects':
          objects = child;
        case 'resources':
          for (final r in child.childElements) {
            if (r.name.local != 'systemColor') {
              throw XibUnsupported('<resources> <${r.name.local}>');
            }
            _systemColors[r.getAttribute('name')!] = r;
          }
        default:
          throw XibUnsupported('<${child.name.local}> in <document>');
      }
    }
    if (objects == null) throw const XibUnsupported('no <objects>');

    // Pass 1: parse the view tree.
    final topLevel = <XmlElement>[];
    for (final e in objects.childElements) {
      final name = e.name.local;
      if (name == 'placeholder') {
        topLevel.add(e);
      } else if (_viewTags.contains(name)) {
        topLevel.add(e);
        _topViews.add(_parseView(e, null));
      } else {
        throw XibUnsupported('top level <$name>');
      }
    }
    for (final v in _views.values) {
      _collectConstrained(v);
    }

    // Pass 2: build the objects.
    final topNodes = <XibNode>[];
    final top = List<XibView>.of(_topViews);
    for (final e in topLevel) {
      if (e.name.local == 'placeholder') {
        topNodes.add(_placeholder(e));
      } else {
        final v = top.removeAt(0);
        _buildView(v);
        topNodes.add(v.node);
      }
    }
    for (final v in _views.values) {
      _usesUIKitEncoder |= v.tag != 'view';
    }

    final connections = _connections(objects);
    final accessibility = _accessibility();
    _usesUIKitEncoder |= accessibility.isNotEmpty;

    final nibRoot = XibNode('NSObject')
      ..ref('UINibTopLevelObjectsKey', XibNode('NSArray')..inlined(topNodes))
      ..ref(
        'UINibObjectsKey',
        XibNode('NSArray')..inlined(_objectList(topNodes)),
      )
      ..ref(
        'UINibConnectionsKey',
        connections.isEmpty
            ? pool.emptyArray
            : (XibNode('NSArray')..inlined(connections)),
      )
      ..ref('UINibVisibleWindowsKey', pool.emptyArray)
      ..ref(
        'UINibAccessibilityConfigurationsKey',
        accessibility.isEmpty
            ? pool.emptyArray
            : (XibNode('NSArray')..inlined(accessibility)),
      )
      ..ref('UINibTraitStorageListsKey', pool.emptyArray)
      ..ref('UINibKeyValuePairsKey', pool.emptyArray);
    if (!_usesUIKitEncoder) {
      nibRoot.scalar(NibValue.integer('IBUINibLNEVersionKey', 1));
    }
    return XibGraphWriter.write(nibRoot);
  }

  // ---------------------------------------------------------------------
  // Parsing.

  XibView _parseView(XmlElement e, XibView? parent) {
    final id = e.getAttribute('id');
    if (id == null) throw XibUnsupported('<${e.name.local}> without id');
    final rect = e.childElements.where(
      (c) => c.name.local == 'rect' && c.getAttribute('key') == 'frame',
    );
    if (rect.isEmpty) throw XibUnsupported('$id has no frame');
    final r = rect.first;
    final item = XibLayoutItem(
      id,
      _num(r, 'x'),
      _num(r, 'y'),
      _num(r, 'width'),
      _num(r, 'height'),
      parent?.item,
    );
    final view = XibView(e, item, parent);
    if (_views.containsKey(id)) throw XibUnsupported('duplicate id $id');
    _views[id] = view;
    for (final c in e.childElements) {
      if (c.name.local == 'subviews') {
        for (final s in c.childElements) {
          if (!_viewTags.contains(s.name.local)) {
            throw XibUnsupported('<${s.name.local}> subview');
          }
          view.subviews.add(_parseView(s, view));
        }
      }
    }
    return view;
  }

  void _collectConstrained(XibView v) {
    for (final c in _children(v.element, 'constraints')) {
      for (final k in c.childElements) {
        _constrainedIds
          ..add(k.getAttribute('firstItem') ?? v.id)
          ..add(k.getAttribute('secondItem') ?? '');
      }
    }
  }

  static Iterable<XmlElement> _children(XmlElement e, String name) =>
      e.childElements.where((c) => c.name.local == name);

  static double _num(XmlElement e, String attr) {
    final s = e.getAttribute(attr);
    final v = s == null ? null : double.tryParse(s);
    if (v == null) {
      throw XibUnsupported('<${e.name.local}> $attr="${s ?? ''}"');
    }
    return v;
  }

  // ---------------------------------------------------------------------
  // Placeholders, connections, accessibility.

  XibNode _placeholder(XmlElement e) {
    for (final a in e.attributes) {
      if (!const {
        'placeholderIdentifier',
        'id',
        'userLabel',
        'customClass',
        'customModule',
        'customModuleProvider',
      }.contains(a.name.local)) {
        throw XibUnsupported('placeholder attribute ${a.name.local}');
      }
    }
    for (final c in e.childElements) {
      if (c.name.local != 'connections') {
        throw XibUnsupported('<${c.name.local}> in <placeholder>');
      }
    }
    final ident = e.getAttribute('placeholderIdentifier')!;
    if (ident != 'IBFilesOwner' && ident != 'IBFirstResponder') {
      throw XibUnsupported('placeholder $ident');
    }
    final node = XibNode('UIProxyObject')
      ..ref('UIProxiedObjectIdentifier', pool.string(ident));
    _placeholders[e.getAttribute('id')!] = node;
    return node;
  }

  XibNode _nodeFor(String id) {
    final node = _placeholders[id] ?? _views[id]?.node;
    if (node == null) throw XibUnsupported('reference to unknown id $id');
    return node;
  }

  List<XibNode> _connections(XmlElement objects) {
    final outlets = <(String, XibNode, XibNode)>[];
    void collect(XmlElement e, String sourceId) {
      for (final c in _children(e, 'connections')) {
        for (final o in c.childElements) {
          if (o.name.local != 'outlet') {
            throw XibUnsupported('<${o.name.local}> connection');
          }
          for (final a in o.attributes) {
            if (!const {
              'property',
              'destination',
              'id',
            }.contains(a.name.local)) {
              throw XibUnsupported('outlet attribute ${a.name.local}');
            }
          }
          outlets.add((
            o.getAttribute('property')!,
            _nodeFor(sourceId),
            _nodeFor(o.getAttribute('destination')!),
          ));
        }
      }
    }

    for (final e in objects.childElements) {
      if (e.name.local == 'placeholder') collect(e, e.getAttribute('id')!);
    }
    for (final v in _views.values) {
      collect(v.element, v.id);
    }
    final sorted = List.of(outlets);
    _stableSort(sorted, (a, b) => a.$1.compareTo(b.$1));
    return [
      for (final (label, source, destination) in sorted)
        XibNode('UIRuntimeOutletConnection')
          ..ref('UILabel', pool.string(label))
          ..ref('UISource', source)
          ..ref('UIDestination', destination),
    ];
  }

  static void _stableSort<T>(List<T> list, int Function(T, T) cmp) {
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      final r = cmp(a.$2, b.$2);
      return r != 0 ? r : a.$1.compareTo(b.$1);
    });
    for (var i = 0; i < list.length; i++) {
      list[i] = indexed[i].$2;
    }
  }

  List<XibNode> _accessibility() {
    final out = <XibNode>[];
    for (final v in _views.values) {
      for (final a in _children(v.element, 'accessibility')) {
        if (a.getAttribute('key') != 'accessibilityConfiguration' ||
            a.attributes.length != 1) {
          throw const XibUnsupported('accessibility attributes');
        }
        final config = XibNode('UIRuntimeAccessibilityConfiguration')
          ..ref('UIAccessibileObject', v.node);
        XibNode? isElement;
        for (final c in a.childElements) {
          if (c.name.local == 'accessibilityTraits' &&
              c.getAttribute('key') == 'traits') {
            var traits = 0;
            for (final t in c.attributes) {
              if (t.name.local == 'key') continue;
              if (t.name.local != 'notEnabled' || t.value != 'YES') {
                throw XibUnsupported('accessibility trait ${t.name.local}');
              }
              traits |= 256;
            }
            config.ref('UIAccessibilityTraits', pool.intNumber(traits));
          } else if (c.name.local == 'bool' &&
              c.getAttribute('key') == 'isElement') {
            isElement = pool.intNumber(
              c.getAttribute('value') == 'YES' ? 1 : 0,
            );
          } else {
            throw XibUnsupported('accessibility <${c.name.local}>');
          }
        }
        if (isElement != null) {
          config.ref('UIIsAccessibilityElement', isElement);
        }
        out.add(config);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // The UINibObjectsKey list: top level objects, then a breadth first walk
  // of the views emitting each view's layout guides, constraints and
  // subviews.

  final Map<XibView, List<XibNode>> _ownedConstraints = Map.identity();
  final Map<XibView, XibNode> _guideStubs = Map.identity();

  List<XibNode> _objectList(List<XibNode> topNodes) {
    final out = List.of(topNodes);
    final queue = List.of(_topViews);
    while (queue.isNotEmpty) {
      final v = queue.removeAt(0);
      final guide = _guideStubs[v];
      if (guide != null) out.add(guide);
      out.addAll(_ownedConstraints[v] ?? const []);
      for (final s in v.subviews) {
        out.add(s.node);
        queue.add(s);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // Views.

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
    'topLeft': 9,
    'topRight': 10,
    'bottomLeft': 11,
    'bottomRight': 12,
  };

  static const _commonAttributes = {
    'id',
    'contentMode',
    'opaque',
    'hidden',
    'tag',
    'alpha',
    'clipsSubviews',
    'clearsContextBeforeDrawing',
    'userInteractionEnabled',
    'horizontalHuggingPriority',
    'verticalHuggingPriority',
    'horizontalCompressionResistancePriority',
    'verticalCompressionResistancePriority',
    'insetsLayoutMarginsFromSafeArea',
    'translatesAutoresizingMaskIntoConstraints',
    'customClass',
    'customModule',
    'customModuleProvider',
    // Interface Builder canvas state, not compiled.
    'ambiguous',
    'misplaced',
    'fixedFrame',
    'userLabel',
  };

  static const _tagAttributes = {
    'view': <String>{},
    'imageView': <String>{},
    'stackView': <String>{},
    'label': {
      'text',
      'textAlignment',
      'lineBreakMode',
      'numberOfLines',
      'baselineAdjustment',
      'adjustsFontSizeToFit',
      'adjustsFontForContentSizeCategory',
      'enabled',
    },
    'button': {
      'contentHorizontalAlignment',
      'contentVerticalAlignment',
      'buttonType',
      'lineBreakMode',
    },
  };

  static const _uiClassNames = {
    'view': 'UIView',
    'label': 'UILabel',
    'button': 'UIButton',
    'imageView': 'UIImageView',
    'stackView': 'UIStackView',
  };

  void _buildView(XibView v) {
    final e = v.element;
    final tag = v.tag;
    for (final a in e.attributes) {
      final n = a.name.local;
      if (!_commonAttributes.contains(n) && !_tagAttributes[tag]!.contains(n)) {
        throw XibUnsupported('<$tag> attribute $n');
      }
    }
    final customClass = e.getAttribute('customClass');
    final node = XibNode(
      customClass == null ? _uiClassNames[tag]! : 'UIClassSwapper',
    );
    v.node = node;
    // Subviews are built before anything references them.
    for (final s in v.subviews) {
      _buildView(s);
    }

    final children = <String, XmlElement>{};
    final colors = <String, XmlElement>{};
    var hasAutoresizingMask = false;
    var autoresizingMask = 0;
    for (final c in e.childElements) {
      final key = c.getAttribute('key');
      switch (c.name.local) {
        case 'rect' when key == 'frame':
        case 'subviews' || 'constraints' || 'connections' || 'accessibility':
        case 'state' when tag == 'button':
        case 'point' when key == 'canvasLocation':
        case 'freeformSimulatedSizeMetrics' || 'simulatedMetricsContainer':
          break;
        case 'autoresizingMask' when key == 'autoresizingMask':
          hasAutoresizingMask = true;
          autoresizingMask = _autoresizingMask(c);
        case 'color' || 'nil':
          colors[key!] = c;
        case 'viewLayoutGuide' when key == 'safeArea':
          final guideId = c.getAttribute('id')!;
          if (_constrainedIds.contains(guideId)) {
            throw const XibUnsupported('constraints to the safe area guide');
          }
          _guideStubs[v] = XibNode('UILayoutGuide')
            ..scalar(const NibValue.nil('UILayoutGuideOwningView'))
            ..ref('UILayoutGuideIdentifier', pool.string(''))
            ..scalar(const NibValue.no('UILayoutGuideOwningViewIsLocked'))
            ..scalar(const NibValue.no('UILayoutGuideShouldBeArchived'))
            ..scalar(
              const NibValue.no('UILayoutGuideAllowsNegativeDimensions'),
            );
        default:
          if (key == null || children.containsKey(key)) {
            throw XibUnsupported('<$tag> child <${c.name.local}>');
          }
          children[key] = c;
      }
    }

    final f = v.item;
    node
      ..scalar(NibValue.bytes('UIBounds', _rect(0, 0, f.width, f.height)))
      ..scalar(
        NibValue.bytes(
          'UICenter',
          _point(f.x + f.width / 2, f.y + f.height / 2),
        ),
      );
    if (v.subviews.isNotEmpty) {
      node.ref(
        'UISubviews',
        XibNode('NSMutableArray')
          ..inlined([for (final s in v.subviews) s.node]),
      );
    }
    final background = colors.remove('backgroundColor');
    if (background != null && background.name.local == 'color') {
      node.ref('UIBackgroundColor', _color(background));
    }
    node.scalar(const NibValue.yes('UIDeepDrawRect'));
    if (e.getAttribute('opaque') != 'NO') {
      node.scalar(const NibValue.yes('UIOpaque'));
    }
    if (_yes(e, 'hidden')) node.scalar(const NibValue.yes('UIHidden'));
    final tagValue = e.getAttribute('tag');
    if (tagValue != null) {
      node.scalar(NibValue.integer('UITag', int.parse(tagValue)));
    }
    if (e.getAttribute('userInteractionEnabled') == 'NO') {
      node.scalar(const NibValue.yes('UIUserInteractionDisabled'));
    }
    node.scalar(const NibValue.yes('UIAutoresizeSubviews'));
    final tamic = e.getAttribute('translatesAutoresizingMaskIntoConstraints');
    final mask = hasAutoresizingMask ? autoresizingMask : 36;
    if (!hasAutoresizingMask && tamic != 'NO') {
      throw XibUnsupported('$tag ${v.id} without autoresizingMask');
    }
    if (mask != 0) node.scalar(NibValue.integer('UIAutoresizingMask', mask));
    final alpha = e.getAttribute('alpha');
    if (alpha != null) {
      node.scalar(NibValue.float('UIAlpha', f32(double.parse(alpha))));
    }
    if (e.getAttribute('clearsContextBeforeDrawing') == 'NO') {
      node.scalar(const NibValue.no('UIClearsContextBeforeDrawing'));
    }
    final contentMode =
        _contentModes[e.getAttribute('contentMode') ?? 'scaleToFill'];
    if (contentMode == null) {
      throw XibUnsupported('contentMode ${e.getAttribute('contentMode')}');
    }
    if (contentMode != 0) {
      node.scalar(NibValue.integer('UIContentMode', contentMode));
    }
    if (_yes(e, 'clipsSubviews')) {
      node.scalar(const NibValue.yes('UIClipsToBounds'));
    }
    final tint = colors.remove('tintColor');
    if (tint != null && tint.name.local == 'color') {
      node.ref('UITintColor', _color(tint));
    }
    if (tamic == 'NO' && (v.parent == null || _constrainedIds.contains(v.id))) {
      node.scalar(
        const NibValue.yes(
          'UIViewDoesNotTranslateAutoresizingMaskIntoConstraints',
        ),
      );
    }
    final constraints = _constraints(v);
    if (constraints.isNotEmpty) {
      _ownedConstraints[v] = constraints;
      node.ref(
        'UIViewAutolayoutConstraints',
        XibNode('NSMutableArray')..inlined(constraints),
      );
    }
    _priorityPair(
      node,
      e,
      'UIViewContentHuggingPriority',
      'horizontalHuggingPriority',
      'verticalHuggingPriority',
      250,
    );
    _priorityPair(
      node,
      e,
      'UIViewContentCompressionResistancePriority',
      'horizontalCompressionResistancePriority',
      'verticalCompressionResistancePriority',
      750,
    );
    if (tag == 'stackView') {
      node.scalar(NibValue.bytes('UIViewLayoutMargins', _insets(0, 0, 0, 0)));
    }
    if (e.getAttribute('insetsLayoutMarginsFromSafeArea') == 'NO') {
      node.scalar(NibValue.integer('UIViewInsetsLayoutMarginsFromSafeArea', 0));
    }
    node
      ..scalar(NibValue.integer('UIViewSemanticContentAttribute', 0))
      ..scalar(const NibValue.nil('UIViewLargeContentStoredProperties'));

    switch (tag) {
      case 'label':
        _label(v, children, colors);
      case 'button':
        _button(v, children);
      case 'stackView':
        node
          ..ref(
            'UIStackViewArrangedSubviews',
            XibNode('NSArray')..inlined([for (final s in v.subviews) s.node]),
          )
          ..scalar(NibValue.integer('UIStackViewAxis', 0))
          ..scalar(NibValue.integer('UIStackViewDistribution', 0))
          ..scalar(NibValue.integer('UIStackViewAlignment', 0))
          ..scalar(const NibValue.double('UIStackViewSpacing', 0))
          ..scalar(const NibValue.no('UIStackViewBaselineRelative'))
          ..scalar(const NibValue.no('UIStackViewLayoutMarginsRelative'));
    }
    if (children.isNotEmpty) {
      throw XibUnsupported('<$tag> <${children.values.first.name.local}>');
    }
    if (colors.isNotEmpty) {
      throw XibUnsupported('<$tag> color ${colors.keys.first}');
    }
    if (customClass != null) {
      final provider = e.getAttribute('customModuleProvider');
      final customModule = e.getAttribute('customModule');
      String className;
      if (provider == 'target') {
        className = _mangle(module, customClass);
      } else if (provider != null || customModule != null) {
        throw const XibUnsupported('customModule');
      } else {
        className = customClass;
      }
      node
        ..ref('UIClassName', pool.string(className))
        ..ref('UIOriginalClassName', pool.string(_uiClassNames[tag]!));
    }
  }

  static String _mangle(String module, String cls) =>
      '_TtC${module.length}$module${cls.length}$cls';

  static bool _yes(XmlElement e, String attr) => e.getAttribute(attr) == 'YES';

  static int _autoresizingMask(XmlElement e) {
    const bits = {
      'flexibleMinX': 1,
      'widthSizable': 2,
      'flexibleMaxX': 4,
      'flexibleMinY': 8,
      'heightSizable': 16,
      'flexibleMaxY': 32,
    };
    var mask = 0;
    for (final a in e.attributes) {
      if (a.name.local == 'key') continue;
      final bit = bits[a.name.local];
      if (bit == null || a.value != 'YES') {
        throw XibUnsupported('autoresizingMask ${a.name.local}');
      }
      mask |= bit;
    }
    return mask;
  }

  void _priorityPair(
    XibNode node,
    XmlElement e,
    String key,
    String h,
    String v,
    int fallback,
  ) {
    final hs = e.getAttribute(h);
    final vs = e.getAttribute(v);
    if (hs == null && vs == null) return;
    int parse(String? s) {
      if (s == null) return fallback;
      final n = int.tryParse(s);
      if (n == null) throw XibUnsupported('$h/$v $s');
      return n;
    }

    final hp = parse(hs);
    final vp = parse(vs);
    if (hp == fallback && vp == fallback) return;
    node.ref(key, pool.string('{$hp, $vp}'));
  }

  static Uint8List _doubles(List<double> values) {
    final b = ByteData(1 + 8 * values.length)..setUint8(0, 7);
    for (var i = 0; i < values.length; i++) {
      b.setFloat64(1 + 8 * i, values[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }

  static Uint8List _rect(double x, double y, double w, double h) =>
      _doubles([x, y, w, h]);

  static Uint8List _point(double x, double y) => _doubles([x, y]);

  static Uint8List _insets(double t, double l, double b, double r) =>
      _doubles([t, l, b, r]);

  // ---------------------------------------------------------------------
  // Constraints.

  static const _attributes = {
    'left': 1,
    'right': 2,
    'top': 3,
    'bottom': 4,
    'leading': 5,
    'trailing': 6,
    'width': 7,
    'height': 8,
    'centerX': 9,
    'centerY': 10,
  };

  List<XibNode> _constraints(XibView v) {
    final parsed = <XibOrderedConstraint>[];
    final elements = <XibOrderedConstraint, XmlElement>{};
    for (final c in _children(v.element, 'constraints')) {
      for (final k in c.childElements) {
        if (k.name.local != 'constraint') {
          throw XibUnsupported('<${k.name.local}> in <constraints>');
        }
        for (final a in k.attributes) {
          if (!const {
            'id',
            'firstItem',
            'firstAttribute',
            'secondItem',
            'secondAttribute',
            'relation',
            'multiplier',
            'constant',
            'priority',
            'identifier',
            'symbolic',
          }.contains(a.name.local)) {
            throw XibUnsupported('constraint attribute ${a.name.local}');
          }
        }
        XibView item(String id) {
          final view = _views[id];
          if (view == null) {
            throw XibUnsupported('constraint item $id is not a view');
          }
          return view;
        }

        int attribute(String? name) {
          final a = _attributes[name];
          if (a == null) throw XibUnsupported('constraint attribute $name');
          return a;
        }

        final first = item(k.getAttribute('firstItem') ?? v.id);
        final secondId = k.getAttribute('secondItem');
        final second = secondId == null ? null : item(secondId);
        if (second == null && k.getAttribute('secondAttribute') != null) {
          throw const XibUnsupported('constraint without secondItem');
        }
        final priority = k.getAttribute('priority');
        final oc = XibOrderedConstraint(
          id: k.getAttribute('id')!,
          first: first.item,
          firstAttribute: attribute(k.getAttribute('firstAttribute')),
          second: second?.item,
          secondAttribute: second == null
              ? 0
              : attribute(k.getAttribute('secondAttribute')),
          constant: double.parse(k.getAttribute('constant') ?? '0'),
          priority: priority == null ? 1000 : double.parse(priority),
          relation: switch (k.getAttribute('relation')) {
            null => 0,
            'lessThanOrEqual' => -1,
            'greaterThanOrEqual' => 1,
            final r => throw XibUnsupported('relation $r'),
          },
        );
        if (second == null &&
            oc.firstAttribute != 7 &&
            oc.firstAttribute != 8) {
          throw XibUnsupported('absolute ${k.getAttribute('firstAttribute')}');
        }
        parsed.add(oc);
        elements[oc] = k;
      }
    }
    return [
      for (final oc in XibConstraintOrder.sort(parsed, v.item))
        _constraintNode(oc, elements[oc]!),
    ];
  }

  XibNode _constraintNode(XibOrderedConstraint c, XmlElement e) {
    final node = XibNode('NSLayoutConstraint')
      ..ref('NSFirstItem', _views[c.first.id]!.node)
      ..scalar(NibValue.integer('NSFirstAttributeV2', c.firstAttribute))
      ..scalar(NibValue.integer('NSFirstAttribute', c.firstAttribute));
    if (c.relation != 0) {
      node.scalar(NibValue.integer('NSRelation', c.relation));
    }
    final m = e.getAttribute('multiplier');
    if (m != null) {
      final parts = m.split(':');
      final value = parts.length == 2
          ? double.parse(parts[0]) / double.parse(parts[1])
          : double.parse(m);
      final stored = f32(value);
      if (stored != 1) node.scalar(NibValue.double('NSMultiplier', stored));
    }
    final second = c.second;
    if (second != null) {
      node
        ..ref('NSSecondItem', _views[second.id]!.node)
        ..scalar(NibValue.integer('NSSecondAttributeV2', c.secondAttribute))
        ..scalar(NibValue.integer('NSSecondAttribute', c.secondAttribute));
    }
    if (c.constant != 0) {
      node.scalar(NibValue.double('NSConstantV2', c.constant));
    }
    node.scalar(const NibValue.yes('NSShouldBeArchived'));
    if (c.priority != 1000) {
      if (c.priority != c.priority.roundToDouble()) {
        throw XibUnsupported('fractional priority ${c.priority}');
      }
      node.scalar(NibValue.integer('NSPriority', c.priority.toInt()));
    }
    final identifier = e.getAttribute('identifier');
    if (identifier != null) {
      node.ref('NSLayoutIdentifier', pool.string(identifier));
    }
    if (c.constant != 0) {
      node.scalar(NibValue.double('NSConstant', c.constant));
    }
    return node;
  }

  // ---------------------------------------------------------------------
  // Labels and buttons.

  void _label(
    XibView v,
    Map<String, XmlElement> children,
    Map<String, XmlElement> colors,
  ) {
    final e = v.element;
    final node = v.node;
    if (e.getAttribute('adjustsFontSizeToFit') != 'NO') {
      throw const XibUnsupported('label adjustsFontSizeToFit');
    }
    final text = e.getAttribute('text');
    if (text == null) throw const XibUnsupported('label without text');
    node.ref('UIText', pool.string(text));
    if (_yes(e, 'adjustsFontForContentSizeCategory')) {
      node.scalar(const NibValue.yes('UIAdjustsFontForContentSizeCategory'));
    }
    final font = children.remove('fontDescription');
    if (font == null) throw const XibUnsupported('label without font');
    node.ref('UIFont', _font(font));
    final textColor = colors.remove('textColor');
    if (textColor == null) throw const XibUnsupported('label textColor');
    final explicitTextColor = textColor.name.local == 'color';
    node.ref(
      'UITextColor',
      explicitTextColor
          ? _color(textColor)
          : _grayColor(0, 1, name: 'labelColor'),
    );
    final highlighted = colors.remove('highlightedColor');
    if (highlighted == null) {
      throw const XibUnsupported('label highlightedColor');
    }
    if (highlighted.name.local == 'color') {
      node.ref('UIHighlightedColor', _color(highlighted));
    }
    final shadowColor = colors.remove('shadowColor');
    if (shadowColor != null && shadowColor.name.local == 'color') {
      node.ref('UIShadowColor', _color(shadowColor));
    }
    final shadow = children.remove('shadowOffset');
    final sw = shadow == null ? 0.0 : _num(shadow, 'width');
    final sh = shadow == null ? -1.0 : _num(shadow, 'height');
    if (sw != 0 || sh != 0) {
      node.scalar(NibValue.bytes('UIShadowOffset', _point(sw, sh)));
    }
    final lines = int.parse(e.getAttribute('numberOfLines') ?? '1');
    if (lines != 1) node.scalar(NibValue.integer('UINumberOfLines', lines));
    final baseline = switch (e.getAttribute('baselineAdjustment')) {
      'alignBaselines' => 0,
      null || 'alignCenters' => 1,
      'none' => 2,
      final b => throw XibUnsupported('baselineAdjustment $b'),
    };
    if (baseline != 0) {
      node.scalar(NibValue.integer('UIBaselineAdjustment', baseline));
    }
    final lineBreak = _lineBreakMode(e.getAttribute('lineBreakMode'));
    if (lineBreak != 4) {
      node.scalar(NibValue.integer('UILineBreakMode', lineBreak));
    }
    node.scalar(
      NibValue.integer('UITextAlignment', switch (e.getAttribute(
        'textAlignment',
      )) {
        null || 'left' => 0,
        'center' => 1,
        'right' => 2,
        'justified' => 3,
        'natural' => 4,
        final a => throw XibUnsupported('textAlignment $a'),
      }),
    );
    if (e.getAttribute('enabled') == 'NO') {
      node.scalar(const NibValue.no('UIEnabled'));
    }
    node.scalar(
      explicitTextColor
          ? const NibValue.yes(
              'UIDisableUpdateTextColorOnTraitCollectionChange',
            )
          : const NibValue.no(
              'UIDisableUpdateTextColorOnTraitCollectionChange',
            ),
    );
  }

  static int _lineBreakMode(String? mode) => switch (mode) {
    'wordWrap' => 0,
    'characterWrap' => 1,
    'clip' => 2,
    'headTruncation' => 3,
    null || 'tailTruncation' => 4,
    'middleTruncation' => 5,
    final m => throw XibUnsupported('lineBreakMode $m'),
  };

  static int _alignment(String? a, String axis) => switch (a) {
    null || 'center' => 0,
    'left' || 'top' => 1,
    'right' || 'bottom' => 2,
    'fill' => 3,
    final x => throw XibUnsupported('$axis alignment $x'),
  };

  void _button(XibView v, Map<String, XmlElement> children) {
    final e = v.element;
    final node = v.node;
    final vertical = _alignment(
      e.getAttribute('contentVerticalAlignment'),
      'vertical',
    );
    final horizontal = _alignment(
      e.getAttribute('contentHorizontalAlignment'),
      'horizontal',
    );
    if (vertical != 0) {
      node
        ..scalar(NibValue.integer('UIContentVerticalAlignment', vertical))
        ..scalar(NibValue.integer('UIContentVerticalAlignment2', vertical));
    }
    if (horizontal != 0) {
      node.scalar(NibValue.integer('UIContentHorizontalAlignment', horizontal));
    }
    const states = {
      'normal': 0,
      'highlighted': 1,
      'disabled': 2,
      'selected': 4,
    };
    final content = <XibNode>[];
    final stateElements = _children(e, 'state').toList()
      ..sort(
        (a, b) => (states[a.getAttribute('key')] ?? -1).compareTo(
          states[b.getAttribute('key')] ?? -1,
        ),
      );
    for (final s in stateElements) {
      final state = states[s.getAttribute('key')];
      if (state == null) {
        throw XibUnsupported('button state ${s.getAttribute('key')}');
      }
      for (final a in s.attributes) {
        if (a.name.local != 'key' && a.name.local != 'title') {
          throw XibUnsupported('button state attribute ${a.name.local}');
        }
      }
      final c = XibNode('UIButtonContent');
      final title = s.getAttribute('title');
      if (title != null) c.ref('UITitle', pool.string(title));
      for (final child in s.childElements) {
        if (child.name.local == 'color' &&
            child.getAttribute('key') == 'titleColor') {
          c.ref('UITitleColor', _color(child));
        } else {
          throw XibUnsupported('button state <${child.name.local}>');
        }
      }
      content
        ..add(pool.intNumber(state))
        ..add(c);
    }
    if (content.isNotEmpty) {
      node.ref(
        'UIButtonStatefulContent',
        XibNode('NSMutableDictionary')..inlined(content),
      );
    }
    final lineBreak = _lineBreakMode(
      e.getAttribute('lineBreakMode') ?? 'middleTruncation',
    );
    if (lineBreak != 5) {
      node.scalar(NibValue.integer('UILineBreakMode', lineBreak));
    }
    node
      ..scalar(const NibValue.yes('UIAdjustsImageWhenHighlighted'))
      ..scalar(const NibValue.yes('UIAdjustsImageWhenDisabled'));
    switch (e.getAttribute('buttonType')) {
      case 'system':
        node.scalar(NibValue.integer('UIButtonType', 1));
      case null || 'custom':
        break;
      case final t:
        throw XibUnsupported('buttonType $t');
    }
    final font = children.remove('fontDescription');
    node.ref('UIFont', font == null ? _systemFont('system', 15) : _font(font));
    for (final key in ['contentEdgeInsets', 'titleEdgeInsets']) {
      final inset = children.remove(key);
      if (inset == null) continue;
      if (inset.name.local != 'inset') throw XibUnsupported(key);
      node.scalar(
        NibValue.bytes(
          'UI${key[0].toUpperCase()}${key.substring(1)}',
          _insets(
            _num(inset, 'minY'),
            _num(inset, 'minX'),
            _num(inset, 'maxY'),
            _num(inset, 'maxX'),
          ),
        ),
      );
    }
    node.scalar(const NibValue.nil('UIButtonConfiguration'));
  }

  // ---------------------------------------------------------------------
  // Fonts.

  XibNode _font(XmlElement e) {
    for (final a in e.attributes) {
      if (!const {
        'key',
        'type',
        'pointSize',
        'weight',
      }.contains(a.name.local)) {
        throw XibUnsupported('fontDescription ${a.name.local}');
      }
    }
    var type = e.getAttribute('type');
    final weight = e.getAttribute('weight');
    if (type == 'system' && weight == 'bold') type = 'boldSystem';
    if (type == 'system' && weight != null && weight != 'regular') {
      type = weight;
    } else if (weight != null && weight != 'regular' && weight != 'bold') {
      throw XibUnsupported('font weight $weight on $type');
    }
    return _systemFont(type ?? '', _num(e, 'pointSize'));
  }

  static const _weights = {
    // type: (font name suffix, usage, traits)
    'system': ('Regular', 'CTFontRegularUsage', 0),
    'medium': ('Medium', 'CTFontMediumUsage', 0),
    'semibold': ('Semibold', 'CTFontDemiUsage', 2),
    'heavy': ('Heavy', 'CTFontHeavyUsage', 2),
    'black': ('Black', 'CTFontBlackUsage', 2),
    'light': ('Light', 'CTFontLightUsage', 8),
    'thin': ('Thin', 'CTFontThinUsage', 4),
    'ultraLight': ('Ultralight', 'CTFontUltraLightUsage', 16),
  };

  XibNode _systemFont(String type, double size) => pool.keyed(
    'font $type $size',
    () {
      final bold = type == 'boldSystem';
      final w = bold ? ('Bold', 'CTFontEmphasizedUsage', 2) : _weights[type];
      if (w == null) throw XibUnsupported('font type $type');
      final name = pool.string('.SFUI-${w.$1}');
      final attributes = [
        pool.string('NSCTFontUIUsageAttribute'),
        pool.string(w.$2),
        if (bold) ...[
          pool.string('NSCTFontUIUsageOverrideAttribute'),
          pool.string('CTFontBoldUsage'),
        ],
        pool.string('NSFontSizeAttribute'),
        pool.doubleNumber(size),
      ];
      final descriptor = XibNode('UIFontDescriptor')
        ..ref(
          'UIFontDescriptorAttributes',
          XibNode(bold ? 'NSMutableDictionary' : 'NSDictionary')
            ..inlined(attributes),
        )
        ..scalar(NibValue.integer('UIFontDescriptorOptions', 2147517444));
      return XibNode('UIFont', superclasses: const ['NSFont'])
        ..ref('UIFontName', name)
        ..ref('UIFontDescriptor', descriptor)
        ..scalar(NibValue.double('UIFontPointSize', size))
        ..scalar(const NibValue.nil('UIFontTextStyleForScaling'))
        ..scalar(const NibValue.double('UIFontPointSizeForScaling', 0))
        ..scalar(const NibValue.double('UIFontMaximumPointSizeAfterScaling', 0))
        ..scalar(NibValue.integer('UIFontTraits', w.$3))
        ..scalar(const NibValue.yes('UISystemFont'))
        ..ref('NSName', name)
        ..scalar(NibValue.double('NSSize', size));
    },
  );

  // ---------------------------------------------------------------------
  // Colors.

  XibNode _color(XmlElement e, {String? systemName}) {
    for (final a in e.attributes) {
      if (!const {
        'key',
        'red',
        'green',
        'blue',
        'white',
        'alpha',
        'colorSpace',
        'customColorSpace',
        'systemColor',
      }.contains(a.name.local)) {
        throw XibUnsupported('color attribute ${a.name.local}');
      }
    }
    final system = e.getAttribute('systemColor');
    if (system != null) {
      final resource = _systemColors[system];
      final fallback = resource?.childElements
          .where((c) => c.name.local == 'color')
          .firstOrNull;
      if (fallback == null) {
        throw XibUnsupported('system color $system without a resource');
      }
      return _color(fallback, systemName: system);
    }
    final space = e.getAttribute('colorSpace') == 'custom'
        ? e.getAttribute('customColorSpace')
        : e.getAttribute('colorSpace');
    final alpha = _num(e, 'alpha');
    switch (space) {
      case 'genericGamma22GrayColorSpace':
        return _grayColor(_num(e, 'white'), alpha, name: systemName);
      case 'sRGB':
        double clamp(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);
        return _rgbColor(
          clamp(_num(e, 'red')),
          clamp(_num(e, 'green')),
          clamp(_num(e, 'blue')),
          alpha,
          name: systemName,
        );
      case 'calibratedRGB' || 'displayP3':
        final c = space == 'displayP3'
            ? XibColorTransform.displayP3ToSrgb(
                _num(e, 'red'),
                _num(e, 'green'),
                _num(e, 'blue'),
              )
            : XibColorTransform.genericRgbToSrgb(
                _num(e, 'red'),
                _num(e, 'green'),
                _num(e, 'blue'),
              );
        return _rgbColor(c[0], c[1], c[2], alpha, name: systemName);
      default:
        throw XibUnsupported('color space $space');
    }
  }

  XibNode _grayColor(double white, double alpha, {String? name}) {
    final systemName =
        name ??
        switch ((white, alpha)) {
          (0, 1) => 'blackColor',
          (1, 1) => 'whiteColor',
          (0, 0) => 'clearColor',
          _ => null,
        };
    return pool.keyed('gray $white $alpha $systemName', () {
      final node = XibNode('UIColor', superclasses: const ['NSColor']);
      if (systemName != null) {
        node.ref('UISystemColorName', pool.string(systemName));
      }
      node.scalar(NibValue.integer('UIColorComponentCount', 2));
      _component(node, 'UIWhite', white);
      _component(node, 'UIAlpha', alpha);
      node
        ..scalar(NibValue.string('NSWhite', _components([white], alpha)))
        ..scalar(NibValue.integer('NSColorSpace', 4));
      return node;
    });
  }

  XibNode _rgbColor(
    double r,
    double g,
    double b,
    double alpha, {
    String? name,
  }) => pool.keyed('rgb $r $g $b $alpha $name', () {
    final node = XibNode('UIColor', superclasses: const ['NSColor']);
    if (name != null) node.ref('UISystemColorName', pool.string(name));
    node.scalar(NibValue.integer('UIColorComponentCount', 4));
    _component(node, 'UIRed', r);
    _component(node, 'UIGreen', g);
    _component(node, 'UIBlue', b);
    _component(node, 'UIAlpha', alpha);
    node
      ..scalar(NibValue.string('NSRGB', _components([r, g, b], alpha)))
      ..scalar(NibValue.integer('NSColorSpace', 2));
    return node;
  });

  static void _component(XibNode node, String key, double value) {
    final single = f32(value);
    node.scalar(NibValue.float(key, single));
    if (single != value) node.scalar(NibValue.double('$key-Double', value));
  }

  static String _components(List<double> values, double alpha) => [
    for (final v in values) formatG3(f32(v)),
    if (f32(alpha) != 1) formatG3(f32(alpha)),
  ].join(' ');

  /// C's `%.3g`.
  @visibleForTesting
  static String formatG3(double v) {
    if (v == 0) return v.isNegative ? '-0' : '0';
    final exp = v.toStringAsExponential(2);
    final parts = exp.split('e');
    final e = int.parse(parts[1]);
    String strip(String s) => s.contains('.')
        ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
        : s;
    if (e < -4 || e >= 3) {
      final sign = e < 0 ? '-' : '+';
      return '${strip(parts[0])}e$sign${e.abs().toString().padLeft(2, '0')}';
    }
    return strip(v.toStringAsFixed(2 - e));
  }
}
