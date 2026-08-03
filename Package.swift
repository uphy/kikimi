// swift-tools-version: 6.0
import PackageDescription

// STT is provided by FluidAudio (Swift SPM package, CoreML/ANE-backed Nemotron 3.5 ASR Streaming
// Multilingual model). See `docs/design/11-streaming-stt.md` section 2.3/2.4. This replaces the
// previous sherpa-onnx integration (`CSherpaOnnx` systemLibrary + prebuilt cmake install +
// linker flags), which required a separate build step (`scripts/prepare-sherpa-onnx.sh`) that
// FluidAudio's pure-SPM distribution makes unnecessary.
let package = Package(
    name: "Kikimi",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4"),
        .package(url: "https://github.com/groue/GRMustache.swift", from: "7.0.0"),
        // Global hotkey registration + a SwiftUI shortcut Recorder for the dictation feature
        // (docs/design/25-dictation-mode.md R7). Carbon-based under the hood -- no Input
        // Monitoring permission needed, and key-up is supported (required for the
        // press-and-hold gesture).
        // Pinned below 1.16.1 (not `from:`): that and later versions add `#Preview` macros to
        // `Recorder.swift`, which fail to compile in this environment's Command Line
        // Tools-only toolchain (no Xcode.app -> no `PreviewsMacros` plugin, CLAUDE.md's
        // "実際のビルド経路は xcodebuild ではなく swift build" note).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0")
    ],
    targets: [
        .executableTarget(
            name: "Kikimi",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Mustache", package: "GRMustache.swift"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Kikimi",
            exclude: [
                "Info.plist",
                "Kikimi.entitlements",
                "Resources/Assets.xcassets",
                // Web assets are copied into the .app by `.mise/tasks/build/_default` (Kikimi does
                // not use SPM resource bundles); excluded here so `swift build` does not warn about
                // unhandled files. See `docs/design/39-webview-markdown.md` §9.
                "Resources/editor"
            ],
            // Tools-version 6.0 (needed for the bundled swift-testing, see `KikimiTests` below)
            // would otherwise default both targets to the Swift 6 language mode. That is a separate
            // migration -- strict concurrency across every `@MainActor` boundary in the app -- so
            // the language mode is pinned to what 5.9 already gave us and nothing else changes here.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KikimiTests",
            // `import Testing` resolves against the toolchain's bundled swift-testing (Swift 6+).
            // Declaring the standalone `swiftlang/swift-testing` package instead makes every `@Test`
            // and `@Suite` in the suite emit a deprecation warning -- 180k of them, 97 MB of build
            // output -- and builds the library from source on top of that.
            dependencies: [
                "Kikimi",
                .product(name: "Yams", package: "Yams")
            ],
            path: "KikimiTests",
            resources: [
                // Not referenced from unit tests; kept as the dummy audio source for the
                // kikimi-verify skill (KIKIMI_TEST_INPUT). Declared so SPM does not warn
                // about an unhandled file.
                .copy("Fixtures/sense-voice-ja-sample.wav")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
