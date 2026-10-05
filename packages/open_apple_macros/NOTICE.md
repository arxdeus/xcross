# NOTICE

`open_apple_macros` adapts the Swift sources of
[OpenAppleMacros](https://github.com/xtool-org/OpenAppleMacros) by Kabir
Oberai (upstream commit `e932208`), licensed under the MIT License. See
`LICENSE` for the full license text.

This package as a whole is distributed under the MIT License.

## Adapted files

| This package | Upstream | Notes |
|---|---|---|
| `swift/Package.swift` | `Package.swift` | `SwiftDataMacros` target removed (upstream has no SwiftData macros implemented yet) |
| `swift/Package.resolved` | `Package.resolved` | Pins `swift-syntax` 604.0.0 |
| `swift/Sources/OpenAppleMacrosBase/MacroError.swift` | same path | Unchanged |
| `swift/Sources/OpenAppleMacrosBase/OpenAppleMacrosBase.swift` | same path | Unchanged |
| `swift/Sources/FoundationModelsMacros/GenerableMacro.swift` | same path | Unchanged |
| `swift/Sources/FoundationModelsMacros/GuideMacro.swift` | same path | Unchanged |
| `swift/Sources/FoundationModelsMacros/Macros.swift` | same path | Unchanged |
| `swift/Sources/FoundationModelsMacros/SessionPropertyEntryMacro.swift` | same path | Unchanged |
| `swift/Sources/SwiftUIMacros/AnimatableMacro.swift` | same path | Unchanged |
| `swift/Sources/SwiftUIMacros/EntryMacro.swift` | same path | Unchanged |
| `swift/Sources/SwiftUIMacros/Macros.swift` | same path | Unchanged |
| `swift/Sources/SwiftUIMacros/StateMacro.swift` | same path | Unchanged |
| `swift/Sources/PreviewsMacros/Macros.swift` | same path | Adds `KitViewMacro` (UIKit/AppKit `#Preview`) and `Common` (widget `#Preview`) empty expansions |
| `swift/Sources/OpenAppleMacrosServer/OpenAppleMacros.swift` | same path | Unchanged |
| `swift/Sources/OpenAppleMacrosServer/Modules.swift` | `Sources/OpenAppleMacrosServer/Generated/All.swift` | Hand-maintained module list without `SwiftDataMacros`; kept in sync with the Dart module list by a test |

## Original code (not a port of any upstream file)

- `lib/` — materializes the embedded Swift package into a cache directory,
  builds `OpenAppleMacrosServer` with the host Swift toolchain, publishes
  it atomically, and returns the `swift build` arguments that register the
  host toolchain plugin directory first and the server for the Apple-only
  macro modules.
