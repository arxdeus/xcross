import 'package:embed_annotation/embed_annotation.dart';

part 'preview_macro_stub_source.g.dart';

/// Source of the Swift compiler plugin stub embedded by
/// [GeneratedPluginsPackage.writePreviewMacroStub] — see that symbol's
/// doc comment for what the stub does and why it exists.
///
/// Kept as a real `.c` file on disk (`assets/preview_macro_stub.c`) rather
/// than a Dart string literal so it can be edited, diffed, and compiled
/// standalone like any other C source; `embed` inlines its contents here at
/// build time so the CLI ships it without reading from disk at runtime.
@EmbedStr('assets/preview_macro_stub.c')
const String previewMacroStubSource = _$previewMacroStubSource;
