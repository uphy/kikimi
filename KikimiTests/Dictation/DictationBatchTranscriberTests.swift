import FluidAudio
import Foundation
import Testing

@testable import Kikimi

/// `docs/design/31-dictation-two-pass-decode.md` §7: `resolveModelVersion` receives the *resolved*
/// language (`DictationController.resolveSttEngineConfig`'s output), so the cases below cover the
/// values that actually reach it -- including the default configuration's effective `"ja-JP"`,
/// which an exact `== "ja"` match would silently misroute to `.v3` (TP1's blocker rationale).
///
/// `resolveModelVersion` itself moved to `BatchAsrDecoder` in
/// `docs/design/33-meeting-two-pass-decode.md` MT1 (promoted to a feature-agnostic shared
/// component); these cases are unchanged, just pointed at the new home.
@Suite("DictationBatchTranscriber.resolveModelVersion")
struct DictationBatchTranscriberTests {
    @Test("BCP-47 primary subtag ja selects the Japanese batch model", arguments: ["ja", "ja-JP", "ja_JP", "JA-jp"])
    func japaneseVariants(language: String) {
        #expect(BatchAsrDecoder.resolveModelVersion(language: language) == .tdtJa)
    }

    @Test("everything else selects the multilingual v3 model", arguments: ["auto", "en", "en-US", "de", "zz-unknown", ""])
    func nonJapaneseVariants(language: String) {
        #expect(BatchAsrDecoder.resolveModelVersion(language: language) == .v3)
    }

    // `@MainActor`: `resolveSttEngineConfig` lives on the `@MainActor` `DictationController`.
    @Test("the default configuration (empty dictation.language + stt.language ja-JP) resolves to the Japanese model")
    @MainActor
    func defaultConfigurationComposesToTdtJa() {
        let resolved = DictationController.resolveSttEngineConfig(dictation: .default, stt: SttConfig.default)

        #expect(resolved.language == "ja-JP", "the premise of this regression test: the default effective language is ja-JP")
        #expect(BatchAsrDecoder.resolveModelVersion(language: resolved.language) == .tdtJa)
    }

    @Test("the minimum-sample gate matches FluidAudio's 0.3s floor at 16kHz")
    func minimumSampleCountMatchesModelFloor() {
        #expect(DictationBatchTranscriber.minimumSampleCount == 4_800)
    }
}
