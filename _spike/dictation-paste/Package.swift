// swift-tools-version: 5.9
import PackageDescription

// Standalone spike: probes global hotkey + cross-app text insertion, the two
// capabilities Kikimi has zero existing code for. Kept out of the main package
// on purpose — nothing here is meant to ship as-is.
let package = Package(
    name: "DictationSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DictationSpike", path: "Sources/DictationSpike")
    ]
)
