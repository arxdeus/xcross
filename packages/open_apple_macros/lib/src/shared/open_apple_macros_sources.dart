import 'package:embed_annotation/embed_annotation.dart';
import 'package:meta/meta.dart';

part 'open_apple_macros_sources.g.dart';

@internal
@EmbedStr('../../../swift/Package.resolved')
const String sourcePackageResolved = _$sourcePackageResolved;

@internal
@EmbedStr('../../../swift/Package.swift')
const String sourcePackageSwift = _$sourcePackageSwift;

@internal
@EmbedStr('../../../swift/Sources/FoundationModelsMacros/GenerableMacro.swift')
const String sourceFoundationModelsMacrosGenerableMacroSwift =
    _$sourceFoundationModelsMacrosGenerableMacroSwift;

@internal
@EmbedStr('../../../swift/Sources/FoundationModelsMacros/GuideMacro.swift')
const String sourceFoundationModelsMacrosGuideMacroSwift =
    _$sourceFoundationModelsMacrosGuideMacroSwift;

@internal
@EmbedStr('../../../swift/Sources/FoundationModelsMacros/Macros.swift')
const String sourceFoundationModelsMacrosMacrosSwift =
    _$sourceFoundationModelsMacrosMacrosSwift;

@internal
@EmbedStr(
  '../../../swift/Sources/FoundationModelsMacros/SessionPropertyEntryMacro.swift',
)
const String sourceFoundationModelsMacrosSessionPropertyEntryMacroSwift =
    _$sourceFoundationModelsMacrosSessionPropertyEntryMacroSwift;

@internal
@EmbedStr('../../../swift/Sources/OpenAppleMacrosBase/MacroError.swift')
const String sourceOpenAppleMacrosBaseMacroErrorSwift =
    _$sourceOpenAppleMacrosBaseMacroErrorSwift;

@internal
@EmbedStr(
  '../../../swift/Sources/OpenAppleMacrosBase/OpenAppleMacrosBase.swift',
)
const String sourceOpenAppleMacrosBaseOpenAppleMacrosBaseSwift =
    _$sourceOpenAppleMacrosBaseOpenAppleMacrosBaseSwift;

@internal
@EmbedStr('../../../swift/Sources/OpenAppleMacrosServer/Modules.swift')
const String sourceOpenAppleMacrosServerModulesSwift =
    _$sourceOpenAppleMacrosServerModulesSwift;

@internal
@EmbedStr('../../../swift/Sources/OpenAppleMacrosServer/OpenAppleMacros.swift')
const String sourceOpenAppleMacrosServerOpenAppleMacrosSwift =
    _$sourceOpenAppleMacrosServerOpenAppleMacrosSwift;

@internal
@EmbedStr('../../../swift/Sources/PreviewsMacros/Macros.swift')
const String sourcePreviewsMacrosMacrosSwift =
    _$sourcePreviewsMacrosMacrosSwift;

@internal
@EmbedStr('../../../swift/Sources/SwiftUIMacros/AnimatableMacro.swift')
const String sourceSwiftUIMacrosAnimatableMacroSwift =
    _$sourceSwiftUIMacrosAnimatableMacroSwift;

@internal
@EmbedStr('../../../swift/Sources/SwiftUIMacros/EntryMacro.swift')
const String sourceSwiftUIMacrosEntryMacroSwift =
    _$sourceSwiftUIMacrosEntryMacroSwift;

@internal
@EmbedStr('../../../swift/Sources/SwiftUIMacros/Macros.swift')
const String sourceSwiftUIMacrosMacrosSwift = _$sourceSwiftUIMacrosMacrosSwift;

@internal
@EmbedStr('../../../swift/Sources/SwiftUIMacros/StateMacro.swift')
const String sourceSwiftUIMacrosStateMacroSwift =
    _$sourceSwiftUIMacrosStateMacroSwift;

@internal
const Map<String, String> openAppleMacrosSources = {
  'Package.resolved': sourcePackageResolved,
  'Package.swift': sourcePackageSwift,
  'Sources/FoundationModelsMacros/GenerableMacro.swift':
      sourceFoundationModelsMacrosGenerableMacroSwift,
  'Sources/FoundationModelsMacros/GuideMacro.swift':
      sourceFoundationModelsMacrosGuideMacroSwift,
  'Sources/FoundationModelsMacros/Macros.swift':
      sourceFoundationModelsMacrosMacrosSwift,
  'Sources/FoundationModelsMacros/SessionPropertyEntryMacro.swift':
      sourceFoundationModelsMacrosSessionPropertyEntryMacroSwift,
  'Sources/OpenAppleMacrosBase/MacroError.swift':
      sourceOpenAppleMacrosBaseMacroErrorSwift,
  'Sources/OpenAppleMacrosBase/OpenAppleMacrosBase.swift':
      sourceOpenAppleMacrosBaseOpenAppleMacrosBaseSwift,
  'Sources/OpenAppleMacrosServer/Modules.swift':
      sourceOpenAppleMacrosServerModulesSwift,
  'Sources/OpenAppleMacrosServer/OpenAppleMacros.swift':
      sourceOpenAppleMacrosServerOpenAppleMacrosSwift,
  'Sources/PreviewsMacros/Macros.swift': sourcePreviewsMacrosMacrosSwift,
  'Sources/SwiftUIMacros/AnimatableMacro.swift':
      sourceSwiftUIMacrosAnimatableMacroSwift,
  'Sources/SwiftUIMacros/EntryMacro.swift': sourceSwiftUIMacrosEntryMacroSwift,
  'Sources/SwiftUIMacros/Macros.swift': sourceSwiftUIMacrosMacrosSwift,
  'Sources/SwiftUIMacros/StateMacro.swift': sourceSwiftUIMacrosStateMacroSwift,
};
