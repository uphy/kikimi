// swift-tools-version: 6.0
import PackageDescription

// Standalone so the evaluation can link Qwen3ASR without the main app's constraints. It cannot
// live in KikimiTests: speech-swift's `yyjson` dependency fails to link into a test bundle
// (`-target arm64-apple-macos10.13`, "symbol(s) not found"), in Debug and Release alike, while
// linking fine into the app target. See tools/asr-eval/README.md.
//
// Must be built with xcodebuild, not `swift build` -- SwiftPM does not compile Metal shaders.
let package = Package(
    name: "Qwen3Probe",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/soniqo/speech-swift.git", branch: "main")],
    targets: [
        .executableTarget(
            name: "Qwen3Probe",
            dependencies: [.product(name: "Qwen3ASR", package: "speech-swift")])
    ]
)
