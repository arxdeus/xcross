// swift-tools-version: 6.1

import PackageDescription

let macroTargets: [Target] = [
    .target(
        name: "FoundationModelsMacros",
        dependencies: [
            "OpenAppleMacrosBase",
            .product(name: "SwiftDiagnostics", package: "swift-syntax"),
        ],
    ),
    .target(
        name: "PreviewsMacros",
        dependencies: ["OpenAppleMacrosBase"],
    ),
    .target(
        name: "SwiftUIMacros",
        dependencies: [
            "OpenAppleMacrosBase",
            .product(name: "SwiftDiagnostics", package: "swift-syntax"),
        ],
    ),
]

let macroDependencies = macroTargets.map {
    Target.Dependency.byName(name: $0.name)
}

let package = Package(
    name: "OpenAppleMacros",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .executable(
            name: "OpenAppleMacrosServer",
            targets: ["OpenAppleMacrosServer"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
    ],
    targets: [
        .target(
            name: "OpenAppleMacrosBase",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "OpenAppleMacrosServer",
            dependencies: [
                "OpenAppleMacrosBase",
                .product(name: "_SwiftCompilerPluginMessageHandling", package: "swift-syntax"),
            ] + macroDependencies
        )
    ] + macroTargets
)
