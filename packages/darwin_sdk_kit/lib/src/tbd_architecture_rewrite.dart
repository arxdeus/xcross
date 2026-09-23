/// The Mach-O architectures a released `ld64.lld` cannot parse in a `.tbd`,
/// and the rewrite that makes those stubs readable again.
///
/// Xcode 27 SDKs added the `arm64e.x1` subtype (`CPU_SUBTYPE_ARM64E_X1`, 12)
/// and list it beside `arm64e` in every stub:
///
/// ```yaml
/// targets: [ arm64e-ios, arm64e.x1-ios ]
/// ```
///
/// LLVM only learned that name in `llvm/TextAPI/Architecture.def` with
/// llvm/llvm-project#222721 (merged into `main`; the `release/23.x` backport,
/// llvm/llvm-project#224185, is still open), so every released linker rejects
/// the whole document rather than skipping the slice:
///
/// ```text
/// ld64.lld: error: could not load TAPI file at .../UIKit.tbd: malformed file
/// .../UIKit.tbd:3:32: error: unknown architecture
/// targets: [ arm64e-ios, arm64e.x1-ios ]
///                        ^~~~~~~~~~~~~~
/// ```
///
/// The unknown slice is *renamed* to `arm64e` rather than deleted. Deleting
/// can empty a `targets:` list, and a stub whose top-level list is empty
/// fails differently but just as fatally ("is incompatible with arm64"),
/// while a duplicate target is something the reader already tolerates
/// everywhere it accepts one. Renaming is also a plain token substitution,
/// so it costs a single pass instead of list surgery.
library;

/// Architecture tokens no released `ld64.lld` can parse, mapped to the
/// ABI-compatible one it does know.
const tbdArchitectureAliases = {'arm64e.x1': 'arm64e'};

/// First `ld64.lld` release that parses `arm64e.x1` in a `.tbd`.
///
/// llvm/llvm-project#222721 landed on `main` after the 23.x branch, and its
/// backport (llvm/llvm-project#224185) has not been merged, so no released
/// linker has it yet and 24 is the first that will.
const firstLd64LldWithArm64eX1 = 24;

/// What `ld64.lld` prints when it meets an architecture it does not know.
const unknownArchitectureMarker = 'unknown architecture';

/// What `ld64.lld` prints around [unknownArchitectureMarker].
const unreadableTapiMarker = 'could not load TAPI file';

/// Rewrites the architecture names inside one `.tbd` document.
///
/// A target may appear under `targets`, `exports`, `re-exports`,
/// `reexported-libraries`, `allowable-clients`, `parent-umbrella` or `uuids`,
/// and an unknown name is fatal in every one of them, so the rewrite matches
/// the bare token wherever it occurs instead of keying off any one field.
abstract final class TbdArchitectureRewrite {
  /// [text] with every unparsable architecture renamed, or null when there is
  /// nothing to rewrite.
  ///
  /// The plain substring test comes first because it is what almost every
  /// stub answers with: only an SDK new enough to carry the subtype has
  /// anything to rewrite, and the regex never runs for the rest.
  static String? apply(String text) {
    if (!tbdArchitectureAliases.keys.any(text.contains)) return null;
    final rewritten = text.replaceAllMapped(
      _token,
      (match) => tbdArchitectureAliases[match.group(0)]!,
    );
    return rewritten == text ? null : rewritten;
  }

  /// A token only counts when nothing identifier-like precedes it, so a
  /// symbol that happens to end in the same characters is left alone
  /// (`_my_arm64e.x1` is a symbol name, not a target).
  static final RegExp _token = RegExp(
    r'(?<![A-Za-z0-9_.$])(?:'
    '${tbdArchitectureAliases.keys.map(RegExp.escape).join('|')}'
    r')\b',
  );
}
