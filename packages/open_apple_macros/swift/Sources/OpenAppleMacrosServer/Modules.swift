import OpenAppleMacrosBase
import FoundationModelsMacros
import PreviewsMacros
import SwiftUIMacros

var allMacros: [[any Macro.Type]] { [
    FoundationModelsMacros.all,
    PreviewsMacros.all,
    SwiftUIMacros.all,
] }
