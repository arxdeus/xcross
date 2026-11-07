import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:xcross/src/shared/apple/interface_builder/xib_key_table_order.dart';
import 'package:xcross/src/shared/apple/launch_screen/storyboardc/nib_archive.dart';

/// One object of the nib's object graph before it is laid out in an
/// archive: values are either scalars or references to other nodes.
@internal
final class XibNode {
  XibNode(this.className, {this.superclasses = const []});

  final String className;
  final List<String> superclasses;
  final List<XibEntry> entries = [];

  void scalar(NibValue value) => entries.add(XibEntry(value.key, value, null));

  void ref(String key, XibNode node) => entries.add(XibEntry(key, null, node));

  /// Appends the inlined elements of an `NSArray`/`NSDictionary`.
  void inlined(Iterable<XibNode> elements) {
    scalar(const NibValue.yes('NSInlinedValue'));
    for (final e in elements) {
      ref('UINibEncoderEmptyKey', e);
    }
  }
}

/// A key and either a scalar or a reference.
@internal
@immutable
final class XibEntry {
  const XibEntry(this.key, this.value, this.node);

  final String key;
  final NibValue? value;
  final XibNode? node;
}

/// Lays an [XibNode] graph out as a `NIBArchive`: objects are numbered in
/// the order a depth first walk of the root's values first reaches them,
/// which is the order `UINibEncoder` writes them.
@internal
final class XibGraphWriter {
  const XibGraphWriter._();

  static Uint8List write(XibNode root) {
    final order = <XibNode>[];
    final index = Map<XibNode, int>.identity();
    // Keys enter UINibEncoder's key dictionary as values are encoded, which
    // is depth first: a key, then the object it references.
    final keys = <String>{};
    void visit(XibNode n) {
      index[n] = order.length;
      order.add(n);
      for (final e in n.entries) {
        keys.add(e.key);
        final child = e.node;
        if (child != null && !index.containsKey(child)) visit(child);
      }
    }

    visit(root);
    return NibArchiveWriter.write([
      for (final n in order)
        NibObject(n.className, [
          for (final e in n.entries)
            e.value ?? NibValue.ref(e.key, index[e.node]!),
        ], superclasses: n.superclasses),
    ], keyOrder: (_) => XibKeyTableOrder.order(keys.toList()));
  }
}

/// Uniquing caches for the value objects `UINibEncoder` archives once and
/// references from everywhere (strings, numbers, colors, fonts, the empty
/// array).
@internal
final class XibValuePool {
  final Map<String, XibNode> _strings = {};
  final Map<String, XibNode> _numbers = {};
  final Map<String, XibNode> _keyed = {};
  XibNode? _emptyArray;

  XibNode string(String value) => _strings.putIfAbsent(
    value,
    () => XibNode('NSString')..scalar(NibValue.string('NS.bytes', value)),
  );

  XibNode intNumber(int value) => _numbers.putIfAbsent(
    'i$value',
    () => XibNode('NSNumber')..scalar(NibValue.integer('NS.intval', value)),
  );

  XibNode doubleNumber(double value) => _numbers.putIfAbsent(
    'd$value',
    () => XibNode('NSNumber')..scalar(NibValue.double('NS.dblval', value)),
  );

  /// A node identified by [key]; [create] builds it the first time.
  XibNode keyed(String key, XibNode Function() create) =>
      _keyed.putIfAbsent(key, create);

  XibNode get emptyArray =>
      _emptyArray ??= XibNode('NSArray')..inlined(const []);

  static Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
}
