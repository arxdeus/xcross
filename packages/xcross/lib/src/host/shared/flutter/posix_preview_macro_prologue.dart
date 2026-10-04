import 'package:embed_annotation/embed_annotation.dart';
import 'package:meta/meta.dart';

part 'posix_preview_macro_prologue.g.dart';

@internal
@EmbedStr('assets/posix_preview_macro_prologue.c')
const String posixPreviewMacroPrologue = _$posixPreviewMacroPrologue;
