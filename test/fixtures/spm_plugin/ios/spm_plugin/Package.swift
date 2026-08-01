// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_plugin",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "spm-plugin", type: .dynamic, targets: ["spm_plugin"])
    ],
    targets: [
        .target(name: "spm_plugin")
    ]
)
