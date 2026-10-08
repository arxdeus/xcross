/// Path conventions that replace the hand-maintained architecture registries.
///
/// Every classification is derived from where a file lives, so new
/// components are picked up without editing the linter:
///
/// * `lib/[src/]composition/**` is an application composition root. It is the
///   only library layer allowed to detect the native platform, branch on
///   platform identity, and wire concrete host and target implementations.
/// * `lib/[src/]shared/**` is platform-neutral implementation.
/// * `lib/[src/]host/<os>/**` is owned by one host operating system
///   (`host/shared/**` is shared across hosts).
/// * `lib/[src/]target/<device>/**` is owned by one target device
///   (`target/shared/**` is shared across targets). A `target/<device>` axis
///   may also be nested below a `host/<os>` axis.
/// * `bin/`, `tool/`, and `hook/` are entrypoints. Like composition roots
///   they may touch ambient process state and select platforms.
/// * `test/` is test code. Only declaration hygiene rules apply there.
library;

/// The architectural zone a source file belongs to.
enum Zone {
  /// `lib/**/composition/**`.
  composition,

  /// Any other layered library source under `lib/`.
  library,

  /// `bin/**`.
  entrypoint,

  /// `tool/**` and `hook/**`.
  tool,

  /// `test/**`.
  test,

  /// Anything else (outside `lib`, `bin`, `tool`, `hook`, `test`).
  other,
}

/// Layer directories permitted directly under `lib/` or `lib/src/`.
const libraryLayers = {'composition', 'shared', 'host', 'target'};

/// The shared value of a platform axis.
const sharedAxis = 'shared';

/// A structural classification of one source file.
final class SourceLocation {
  SourceLocation._({
    required this.zone,
    required this.segments,
    required this.layerIndex,
    required this.host,
    required this.target,
    required this.malformedAxis,
  });

  /// Classifies [path], an absolute or package-relative file path.
  ///
  /// When [packageRoot] is supplied the path is interpreted relative to it,
  /// otherwise the first `lib`, `bin`, `tool`, `hook`, or `test` directory in
  /// the path is used as the package-relative anchor.
  factory SourceLocation.of(String path, {String? packageRoot}) {
    final normalized = path.replaceAll(r'\', '/');
    final root = packageRoot?.replaceAll(r'\', '/');
    if (root != null && normalized.startsWith('$root/')) {
      return SourceLocation.relative(
        normalized.substring(root.length + 1).split('/'),
      );
    }
    final parts = normalized.split('/');
    final anchor = parts.indexWhere(_zoneRoots.containsKey);
    return SourceLocation.relative(anchor < 0 ? parts : parts.sublist(anchor));
  }

  /// Classifies a `package:` library URI as `lib/<path>`.
  factory SourceLocation.ofPackageUri(Uri uri) =>
      SourceLocation.relative(['lib', ...uri.pathSegments.skip(1)]);

  /// Classifies package-relative path [segments].
  factory SourceLocation.relative(List<String> segments) {
    final zoneRoot = segments.isEmpty ? null : _zoneRoots[segments.first];
    if (zoneRoot != Zone.library) {
      return SourceLocation._(
        zone: zoneRoot ?? Zone.other,
        segments: segments,
        layerIndex: -1,
        host: sharedAxis,
        target: sharedAxis,
        malformedAxis: false,
      );
    }
    final layerIndex = segments.length > 2 && segments[1] == 'src' ? 2 : 1;
    String axis(String label) {
      final index = segments.indexOf(label, layerIndex);
      if (index < 0 || index + 1 >= segments.length - 1) return sharedAxis;
      return segments[index + 1];
    }

    bool incomplete(String label) {
      final index = segments.indexOf(label, layerIndex);
      if (index < 0) return false;
      if (index != layerIndex && segments[index - 2] != 'host') return false;
      return index + 1 >= segments.length - 1;
    }

    final layer = layerIndex < segments.length - 1
        ? segments[layerIndex]
        : null;
    final target = segments.indexOf('target', layerIndex);
    final targetIsAxis =
        target == layerIndex ||
        target == layerIndex + 2 && segments[layerIndex] == 'host';
    return SourceLocation._(
      zone: layer == 'composition' ? Zone.composition : Zone.library,
      segments: segments,
      layerIndex: layerIndex,
      host: layer == 'host' ? axis('host') : sharedAxis,
      target: targetIsAxis ? axis('target') : sharedAxis,
      malformedAxis:
          (layer == 'host' && incomplete('host')) ||
          (targetIsAxis && incomplete('target')),
    );
  }

  static const _zoneRoots = {
    'lib': Zone.library,
    'bin': Zone.entrypoint,
    'tool': Zone.tool,
    'hook': Zone.tool,
    'test': Zone.test,
  };

  /// The zone of this file.
  final Zone zone;

  /// Package-relative path segments.
  final List<String> segments;

  final int layerIndex;

  /// Concrete host owner, or [sharedAxis].
  final String host;

  /// Concrete target owner, or [sharedAxis].
  final String target;

  /// Whether a `host`/`target` axis directory is missing its owner segment.
  final bool malformedAxis;

  /// The layer directory under `lib/` or `lib/src/`, if any.
  String? get layer => zone == Zone.library || zone == Zone.composition
      ? (layerIndex < segments.length - 1 ? segments[layerIndex] : null)
      : null;

  /// Whether the file is library code under `lib/src/`.
  bool get isImplementation =>
      (zone == Zone.library || zone == Zone.composition) && layerIndex == 2;

  /// Whether the file sits in a recognised library layer.
  bool get hasKnownLayer => libraryLayers.contains(layer) && !malformedAxis;

  /// Whether this file may detect, select, and wire platforms.
  bool get isCompositionRoot =>
      zone == Zone.composition || zone == Zone.entrypoint || zone == Zone.tool;

  /// Whether this file is layered library code that must stay
  /// platform-neutral unless it lives under a concrete axis.
  bool get isLayeredLibrary => zone == Zone.library;

  /// Whether this file is owned by a concrete host.
  bool get concreteHost => host != sharedAxis;

  /// Whether this file is owned by a concrete target.
  bool get concreteTarget => target != sharedAxis;

  /// Whether the file is generated code.
  bool get isGenerated =>
      segments.isNotEmpty && segments.last.endsWith('.g.dart');

  @override
  String toString() =>
      'SourceLocation(${segments.join('/')}, zone: ${zone.name}, '
      'layer: $layer, host: $host, target: $target)';
}
