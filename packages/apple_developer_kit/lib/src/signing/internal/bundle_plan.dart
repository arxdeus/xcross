import 'package:apple_developer_kit/src/signing/internal/loose_binary.dart';
import 'package:apple_developer_kit/src/signing/internal/resolved_bundle.dart';
import 'package:meta/meta.dart';

/// The whole resolved bundle tree a [BundleSigner] is about to sign.
@immutable
final class BundlePlan {
  const BundlePlan(this.bundles, this.looseBinaries);

  final List<ResolvedBundle> bundles;
  final List<LooseBinary> looseBinaries;

  ResolvedBundle get root => bundles.singleWhere((bundle) => bundle.isRoot);
}
