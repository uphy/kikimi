import Foundation
import Testing
import Yams

@testable import Kikimi

/// Layer 1 (unit) coverage for `AppConfig`, targeting `docs/design/13-speaker-diarization.md`
/// section 7's `diarization:` `config.yaml` section. Every test roots `AppConfig` at a fresh
/// temporary directory (via the DI initializer) so nothing here ever touches a real
/// `~/.config/kikimi` (mirrors `AppStateTests`'s own DI convention).
@Suite("AppConfig")
struct AppConfigTests {
    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppConfigTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `credentialStore` defaults to a fresh, empty `InMemoryCredentialStore()` per call (Swift
    /// re-evaluates default arguments at every call site) so the vast majority of tests -- which
    /// construct exactly one `AppConfig` per test -- need no changes at all and never touch the real
    /// Keychain. Tests that reload across two `AppConfig` instances and need the migration's
    /// Keychain write to actually persist between them pass the same instance explicitly (see
    /// `llmSettingsPersistAcrossInstances`, `docs/design/26-settings-ui.md` §6.1).
    private func makeAppConfig(in directory: URL, credentialStore: CredentialStoring = InMemoryCredentialStore()) -> AppConfig {
        AppConfig(directory: directory, credentialStore: credentialStore)
    }

    private func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("config.yaml")
    }

    // MARK: - Defaults

    @Test("missing config.yaml starts with design section 7's documented diarization defaults")
    func missingFileStartsWithDefaults() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.diarization == .default)
        #expect(appConfig.data.diarization.enabled == true)
        #expect(appConfig.data.diarization.selfName == "自分")
        #expect(appConfig.data.diarization.stepMs == 500)
        // 10_000, not the design's original 5_000: WeSpeaker's input window is a fixed 10 seconds, so
        // a shorter gate enrolls voiceprints from half-zero-padded audio (`DiarizationConfig.default`).
        #expect(appConfig.data.diarization.minEnrollSpeechMs == 10_000)
        #expect(appConfig.data.diarization.speakerMatchThreshold == 0.45)
        #expect(appConfig.data.diarization.speakerMatchMargin == 0.05)
        #expect(appConfig.data.diarization.onsetThreshold == 0.5)
        #expect(appConfig.data.diarization.offsetThreshold == 0.5)
        #expect(appConfig.data.diarization.minDurationOnMs == 250)
        #expect(appConfig.data.diarization.minDurationOffMs == 250)
    }

    // MARK: - Round-trip

    @Test("update() writes and persists diarization settings across a fresh AppConfig instance")
    func diarizationSettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.diarization = DiarizationConfig(
                enabled: false,
                selfName: "田中",
                stepMs: 100,
                variant: "dihard3",
                minEnrollSpeechMs: 3_000,
                speakerMatchThreshold: 0.8,
                speakerMatchMargin: 0.1
            )
        }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.diarization == DiarizationConfig(
            enabled: false,
            selfName: "田中",
            stepMs: 100,
            variant: "dihard3",
            minEnrollSpeechMs: 3_000,
            speakerMatchThreshold: 0.8,
            speakerMatchMargin: 0.1
        ))
    }

    @Test("saved YAML uses snake_case keys for diarization")
    func savedYAMLUsesSnakeCase() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let diarization = root?["diarization"] as? [String: Any]
        #expect(diarization?.keys.contains("self_name") == true)
        #expect(diarization?.keys.contains("step_ms") == true)
        #expect(diarization?.keys.contains("min_enroll_speech_ms") == true)
        #expect(diarization?.keys.contains("speaker_match_threshold") == true)
        #expect(diarization?.keys.contains("speaker_match_margin") == true)
        #expect(diarization?.keys.contains("onset_threshold") == true)
        #expect(diarization?.keys.contains("offset_threshold") == true)
        #expect(diarization?.keys.contains("min_duration_on_ms") == true)
        #expect(diarization?.keys.contains("min_duration_off_ms") == true)
    }

    // MARK: - Sample YAML compatibility

    @Test("decodes design section 7's sample config.yaml diarization section")
    func decodesDesignSampleYAML() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        diarization:
          enabled: true
          self_name: 自分
          step_ms: 500
          min_enroll_speech_ms: 10000
          speaker_match_threshold: 0.45
          onset_threshold: 0.5
          offset_threshold: 0.5
          min_duration_on_ms: 250
          min_duration_off_ms: 250
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.diarization == .default)
    }

    @Test("a config.yaml without a diarization: key falls back to DiarizationConfig.default (backward compatible)")
    func missingDiarizationKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a missing diarization: key must not fail the whole decode")
        #expect(appConfig.data.diarization == .default)

        // The lenient decode must not leave save() permanently refused.
        appConfig.update { $0.diarization.enabled = false }
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.diarization.enabled == false)
    }

    @Test("a partial diarization: section (only enabled) fills every other field from DiarizationConfig.default")
    func partialDiarizationSectionFillsMissingFieldsFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A hand-edited config.yaml that only sets `enabled` -- the review finding this regresses:
        // DiarizationConfig's synthesized Decodable conformance requires every key, so this used to
        // throw and fail the *whole* config.yaml decode (not just this section).
        let partialYAML = """
        diarization:
          enabled: false
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a partial diarization: section must not fail the whole config.yaml decode")
        #expect(appConfig.data.diarization.enabled == false, "the field the user did write must still be honored")
        #expect(appConfig.data.diarization.selfName == DiarizationConfig.default.selfName)
        #expect(appConfig.data.diarization.stepMs == DiarizationConfig.default.stepMs)
        #expect(appConfig.data.diarization.minEnrollSpeechMs == DiarizationConfig.default.minEnrollSpeechMs)
        #expect(appConfig.data.diarization.speakerMatchThreshold == DiarizationConfig.default.speakerMatchThreshold)
        #expect(appConfig.data.diarization.speakerMatchMargin == DiarizationConfig.default.speakerMatchMargin)
        #expect(appConfig.data.diarization.onsetThreshold == DiarizationConfig.default.onsetThreshold)
        #expect(appConfig.data.diarization.offsetThreshold == DiarizationConfig.default.offsetThreshold)
        #expect(appConfig.data.diarization.minDurationOnMs == DiarizationConfig.default.minDurationOnMs)
        #expect(appConfig.data.diarization.minDurationOffMs == DiarizationConfig.default.minDurationOffMs)
    }

    // MARK: - LS-EEND timeline post-processing decode (design section 7, 2026-08-01)

    @Test("onset_threshold/offset_threshold and min_duration_on_ms/min_duration_off_ms round-trip when in range")
    func timelinePostProcessingKeysRoundTrip() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        diarization:
          onset_threshold: 0.7
          offset_threshold: 0.4
          min_duration_on_ms: 400
          min_duration_off_ms: 120
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.diarization.onsetThreshold == 0.7)
        #expect(appConfig.data.diarization.offsetThreshold == 0.4)
        #expect(appConfig.data.diarization.minDurationOnMs == 400)
        #expect(appConfig.data.diarization.minDurationOffMs == 120)
    }

    @Test(
        "an out-of-range onset_threshold falls back to the 0.5 default (0 and 1 are both rejected, not clamped)",
        arguments: [-0.1, 0.0, 1.0, 1.5]
    )
    func outOfRangeOnsetThresholdFallsBackToDefault(value: Double) throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        diarization:
          onset_threshold: \(value)
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "an out-of-range threshold must not fail the whole config.yaml decode")
        #expect(appConfig.data.diarization.onsetThreshold == DiarizationConfig.default.onsetThreshold)
    }

    @Test(
        "an out-of-range offset_threshold falls back to the 0.5 default",
        arguments: [0.0, 1.0, 2.0]
    )
    func outOfRangeOffsetThresholdFallsBackToDefault(value: Double) throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        diarization:
          offset_threshold: \(value)
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.diarization.offsetThreshold == DiarizationConfig.default.offsetThreshold)
    }

    @Test("a negative min_duration_on_ms/min_duration_off_ms is clamped to 0 (gate disabled), not restored to the 250 default")
    func negativeMinDurationsAreClampedToZero() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        diarization:
          min_duration_on_ms: -1
          min_duration_off_ms: -500
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a negative duration must not fail the whole config.yaml decode")
        #expect(appConfig.data.diarization.minDurationOnMs == 0)
        #expect(appConfig.data.diarization.minDurationOffMs == 0)
    }

    @Test("min_duration_on_ms: 0 round-trips as exactly 0 (FluidAudio's pass-through behavior, not clamped away)")
    func zeroMinDurationOnRoundTrips() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        diarization:
          min_duration_on_ms: 0
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.diarization.minDurationOnMs == 0)
    }

    // MARK: - speakerMatchMargin decode (design section 20 §3.4)

    @Test("a diarization: section without speaker_match_margin falls back to DiarizationConfig.default's 0.05")
    func missingSpeakerMatchMarginKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialYAML = """
        diarization:
          speaker_match_threshold: 0.7
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.diarization.speakerMatchThreshold == 0.7, "the field the user did write must still be honored")
        #expect(appConfig.data.diarization.speakerMatchMargin == DiarizationConfig.default.speakerMatchMargin)
    }

    @Test("a negative speaker_match_margin is clamped to 0 rather than falling back to the 0.05 default (design section 20 §3.4)")
    func negativeSpeakerMatchMarginIsClampedToZero() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        diarization:
          speaker_match_margin: -0.1
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a negative margin must not fail the whole config.yaml decode")
        #expect(appConfig.data.diarization.speakerMatchMargin == 0, "a negative margin must clamp to 0, not fall back to the 0.05 default")
    }

    @Test("speaker_match_margin: 0 round-trips as exactly 0 (margin check disabled, not clamped away)")
    func zeroSpeakerMatchMarginRoundTrips() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        diarization:
          speaker_match_margin: 0
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.diarization.speakerMatchMargin == 0)
    }

    // MARK: - RefinementConfig defaults

    @Test("missing config.yaml starts with design section 8's documented refinement defaults")
    func missingFileStartsWithRefinementDefaults() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.refinement == .default)
        #expect(appConfig.data.refinement.model == "claude-haiku-4-5-20251001")
        #expect(appConfig.data.refinement.batchSize == 10)
        #expect(appConfig.data.refinement.batchTimeoutMs == 5_000)
        #expect(appConfig.data.refinement.contextSegments == 3)
        #expect(appConfig.data.refinement.contextRefreshBatches == 10)
    }

    // MARK: - RefinementConfig round-trip

    @Test("update() writes and persists refinement settings across a fresh AppConfig instance")
    func refinementSettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.refinement = RefinementConfig(
                model: "claude-sonnet-4-5",
                batchSize: 20,
                batchTimeoutMs: 10_000,
                contextSegments: 5,
                contextRefreshBatches: 3
            )
        }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.refinement == RefinementConfig(
            model: "claude-sonnet-4-5",
            batchSize: 20,
            batchTimeoutMs: 10_000,
            contextSegments: 5,
            contextRefreshBatches: 3
        ))
    }

    @Test("saved YAML uses snake_case keys for refinement")
    func savedYAMLUsesSnakeCaseForRefinement() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let refinement = root?["refinement"] as? [String: Any]
        #expect(refinement?.keys.contains("batch_size") == true)
        #expect(refinement?.keys.contains("batch_timeout_ms") == true)
        #expect(refinement?.keys.contains("context_segments") == true)
        #expect(refinement?.keys.contains("context_refresh_batches") == true)
    }

    // MARK: - RefinementConfig sample YAML compatibility

    @Test("decodes kikimi.md 12 章's sample config.yaml refinement section")
    func decodesDesignSampleRefinementYAML() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        refinement:
          model: claude-haiku-4-5-20251001
          batch_size: 10
          batch_timeout_ms: 5000
          context_segments: 3
          context_refresh_batches: 10
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.refinement == .default)
    }

    @Test("a config.yaml without a refinement: key falls back to RefinementConfig.default (backward compatible)")
    func missingRefinementKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a missing refinement: key must not fail the whole decode")
        #expect(appConfig.data.refinement == .default)

        // The lenient decode must not leave save() permanently refused.
        appConfig.update { $0.refinement.batchSize = 20 }
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.refinement.batchSize == 20)
    }

    @Test("a partial refinement: section (only model) fills every other field from RefinementConfig.default")
    func partialRefinementSectionFillsMissingFieldsFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialYAML = """
        refinement:
          model: claude-sonnet-4-5
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a partial refinement: section must not fail the whole config.yaml decode")
        #expect(appConfig.data.refinement.model == "claude-sonnet-4-5", "the field the user did write must still be honored")
        #expect(appConfig.data.refinement.batchSize == RefinementConfig.default.batchSize)
        #expect(appConfig.data.refinement.batchTimeoutMs == RefinementConfig.default.batchTimeoutMs)
        #expect(appConfig.data.refinement.contextSegments == RefinementConfig.default.contextSegments)
        #expect(appConfig.data.refinement.contextRefreshBatches == RefinementConfig.default.contextRefreshBatches)
    }

    // MARK: - RefinementConfig invalid-value clamping

    @Test("refinement.batch_size < 1 is clamped to RefinementConfig.default.batchSize with a warning")
    func invalidBatchSizeIsClampedToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let invalidYAML = """
        refinement:
          batch_size: 0
        """
        try invalidYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.refinement.batchSize == RefinementConfig.default.batchSize)
    }

    @Test("refinement.batch_timeout_ms < 0 is clamped to RefinementConfig.default.batchTimeoutMs with a warning")
    func invalidBatchTimeoutMsIsClampedToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let invalidYAML = """
        refinement:
          batch_timeout_ms: -1
        """
        try invalidYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.refinement.batchTimeoutMs == RefinementConfig.default.batchTimeoutMs)
    }

    @Test("refinement.context_segments < 0 is clamped to RefinementConfig.default.contextSegments with a warning")
    func invalidContextSegmentsIsClampedToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let invalidYAML = """
        refinement:
          context_segments: -1
        """
        try invalidYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.refinement.contextSegments == RefinementConfig.default.contextSegments)
    }

    @Test("refinement.context_refresh_batches < 1 is clamped to RefinementConfig.default.contextRefreshBatches with a warning")
    func invalidContextRefreshBatchesIsClampedToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let invalidYAML = """
        refinement:
          context_refresh_batches: 0
        """
        try invalidYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.refinement.contextRefreshBatches == RefinementConfig.default.contextRefreshBatches)
    }

    // MARK: - RefinementConfig.dedupSystemLeakSegments (`docs/design/24-system-audio-leak-mitigation.md` §4.3)

    @Test("missing config.yaml defaults dedupSystemLeakSegments to true")
    func missingFileDefaultsDedupSystemLeakSegmentsToTrue() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.refinement.dedupSystemLeakSegments == true)
        #expect(RefinementConfig.default.dedupSystemLeakSegments == true)
    }

    @Test("a refinement: section without dedup_system_leak_segments falls back to true (backward compatible)")
    func missingDedupSystemLeakSegmentsKeyFallsBackToTrue() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialYAML = """
        refinement:
          model: claude-sonnet-4-5
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.refinement.dedupSystemLeakSegments == true)
    }

    @Test("dedup_system_leak_segments: false decodes to false")
    func dedupSystemLeakSegmentsFalseDecodes() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        refinement:
          dedup_system_leak_segments: false
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.refinement.dedupSystemLeakSegments == false)
    }

    @Test("update() writes and persists dedupSystemLeakSegments across a fresh AppConfig instance")
    func dedupSystemLeakSegmentsPersistsAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { $0.refinement.dedupSystemLeakSegments = false }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.refinement.dedupSystemLeakSegments == false)
    }

    @Test("saved YAML uses snake_case dedup_system_leak_segments key")
    func savedYAMLUsesSnakeCaseForDedupSystemLeakSegments() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let refinement = root?["refinement"] as? [String: Any]
        #expect(refinement?.keys.contains("dedup_system_leak_segments") == true)
    }

    // MARK: - AudioConfig (`docs/design/24-system-audio-leak-mitigation.md` §5.3)

    @Test("missing config.yaml defaults audio.suggestHeadphonesOnBuiltInSpeaker to true")
    func missingFileDefaultsSuggestHeadphonesToTrue() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.audio.suggestHeadphonesOnBuiltInSpeaker == true)
        #expect(AudioConfig.default.suggestHeadphonesOnBuiltInSpeaker == true)
    }

    @Test("a config.yaml without an audio: key falls back to AudioConfig.default (backward compatible)")
    func missingAudioKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        refinement:
          model: claude-sonnet-4-5
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.audio == AudioConfig.default)
    }

    @Test("an audio: section without suggest_headphones_on_builtin_speaker falls back to true")
    func missingSuggestHeadphonesKeyFallsBackToTrue() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        audio: {}
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.audio.suggestHeadphonesOnBuiltInSpeaker == true)
    }

    @Test("suggest_headphones_on_builtin_speaker: false decodes to false")
    func suggestHeadphonesFalseDecodes() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        audio:
          suggest_headphones_on_builtin_speaker: false
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.audio.suggestHeadphonesOnBuiltInSpeaker == false)
    }

    @Test("update() writes and persists AudioConfig across a fresh AppConfig instance")
    func audioConfigPersistsAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { $0.audio.suggestHeadphonesOnBuiltInSpeaker = false }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.audio.suggestHeadphonesOnBuiltInSpeaker == false)
    }

    @Test("saved YAML uses snake_case suggest_headphones_on_builtin_speaker key")
    func savedYAMLUsesSnakeCaseForSuggestHeadphones() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let audio = root?["audio"] as? [String: Any]
        #expect(audio?.keys.contains("suggest_headphones_on_builtin_speaker") == true)
    }

    // MARK: - LLMConfig defaults (`docs/design/14-llm-provider.md` section 3)

    @Test("missing config.yaml starts with the documented llm defaults (claude-cli, back-compat)")
    func missingFileStartsWithLLMDefaults() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.llm == .default)
        #expect(appConfig.data.llm.provider == .claudeCLI)
        #expect(appConfig.data.llm.claude.cliPath == nil)
        #expect(appConfig.data.llm.openai == .default)
    }

    @Test("a config.yaml without an llm: key falls back to LLMConfig.default (backward compatible)")
    func missingLLMKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a missing llm: key must not fail the whole decode")
        #expect(appConfig.data.llm == .default)
    }

    @Test("an existing config.yaml (no llm: section, only diarization/refinement) still decodes successfully")
    func existingConfigWithoutLLMSectionStillDecodes() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        diarization:
          enabled: true
        refinement:
          model: claude-haiku-4-5-20251001
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.llm == .default)
    }

    @Test("a partial llm: section (only provider) fills claude/openai from their defaults")
    func partialLLMSectionFillsMissingFieldsFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialYAML = """
        llm:
          provider: openai
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a partial llm: section must not fail the whole config.yaml decode")
        #expect(appConfig.data.llm.provider == .openai, "the field the user did write must still be honored")
        #expect(appConfig.data.llm.claude == ClaudeBackendConfig.default)
        #expect(appConfig.data.llm.openai == OpenAIBackendConfig.default)
    }

    @Test("an unknown llm.provider value falls back to claude-cli")
    func unknownProviderFallsBackToClaudeCLI() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let invalidYAML = """
        llm:
          provider: bedrock
        """
        try invalidYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.llm.provider == .claudeCLI)
    }

    @Test("decodes section 3's full llm: sample (openai/azure-style fields)")
    func decodesFullLLMSampleYAML() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        llm:
          provider: openai
          claude:
            cli_path: /opt/homebrew/bin/claude
          openai:
            base_url: https://res.openai.azure.com/openai/deployments/dep
            api_key: ""
            api_key_env: AZURE_OPENAI_API_KEY
            api_version: "2024-06-01"
            model: gpt-4o-deployment
            auth_header: api-key
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.llm.provider == .openai)
        #expect(appConfig.data.llm.claude.cliPath == "/opt/homebrew/bin/claude")
        #expect(appConfig.data.llm.openai.baseURL == "https://res.openai.azure.com/openai/deployments/dep")
        #expect(appConfig.data.llm.openai.apiKeyEnv == "AZURE_OPENAI_API_KEY")
        #expect(appConfig.data.llm.openai.apiVersion == "2024-06-01")
        #expect(appConfig.data.llm.openai.model == "gpt-4o-deployment")
        #expect(appConfig.data.llm.openai.authHeader == "api-key")
    }

    // MARK: - LLMConfig round-trip

    @Test("update() writes and persists llm settings across a fresh AppConfig instance")
    func llmSettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let credentialStore = InMemoryCredentialStore()

        let appConfig = makeAppConfig(in: dir, credentialStore: credentialStore)
        appConfig.update { config in
            config.llm = LLMConfig(
                provider: .openai,
                claude: ClaudeBackendConfig(cliPath: "/usr/local/bin/claude"),
                openai: OpenAIBackendConfig(
                    baseURL: "https://api.openai.com/v1",
                    apiKey: "sk-test",
                    apiKeyEnv: "",
                    apiVersion: "",
                    model: "gpt-4o-mini",
                    authHeader: "bearer"
                )
            )
        }

        // A fresh `AppConfig` over the same directory + Keychain: its `init` -> `load()` reads
        // "sk-test" off disk and immediately migrates it (`docs/design/26-settings-ui.md` §3.1), so
        // config.yaml's `apiKey` is rewritten to "" and the plaintext moves into `credentialStore`.
        let reloaded = makeAppConfig(in: dir, credentialStore: credentialStore)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.llm.provider == .openai)
        #expect(reloaded.data.llm.claude.cliPath == "/usr/local/bin/claude")
        #expect(reloaded.data.llm.openai.baseURL == "https://api.openai.com/v1")
        #expect(reloaded.data.llm.openai.apiKey == "", "migrated to Keychain on load; config.yaml no longer holds the plaintext")
        #expect(credentialStore.read(account: CredentialAccount.openAIAPIKey) == "sk-test")
        #expect(reloaded.data.llm.openai.model == "gpt-4o-mini")
        #expect(reloaded.data.llm.openai.authHeader == "bearer")
    }

    @Test("saved YAML uses snake_case keys for llm.claude and llm.openai")
    func savedYAMLUsesSnakeCaseForLLM() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.llm = LLMConfig(
                provider: .openai,
                claude: ClaudeBackendConfig(cliPath: "/usr/local/bin/claude"),
                openai: OpenAIBackendConfig(
                    baseURL: "https://api.openai.com/v1",
                    apiKey: "sk-test",
                    apiKeyEnv: "OPENAI_API_KEY",
                    apiVersion: "2024-06-01",
                    model: "gpt-4o-mini",
                    authHeader: "bearer"
                )
            )
        }

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let llm = root?["llm"] as? [String: Any]
        let claude = llm?["claude"] as? [String: Any]
        let openai = llm?["openai"] as? [String: Any]
        #expect(claude?.keys.contains("cli_path") == true)
        #expect(openai?.keys.contains("base_url") == true)
        #expect(openai?.keys.contains("api_key") == true)
        #expect(openai?.keys.contains("api_key_env") == true)
        #expect(openai?.keys.contains("api_version") == true)
        #expect(openai?.keys.contains("auth_header") == true)
    }

    // MARK: - LLMConfig.pricing (`docs/design/16-llm-usage-stats.md` section 4)

    @Test("missing config.yaml starts with an empty llm.pricing table")
    func missingFileStartsWithEmptyPricing() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.llm.pricing.isEmpty)
    }

    @Test("a partial llm: section without a pricing: key falls back to an empty pricing table")
    func missingPricingKeyFallsBackToEmpty() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialYAML = """
        llm:
          provider: openai
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.llm.pricing.isEmpty)
    }

    @Test("decodes design section 4's sample llm.pricing entry, deriving cache_read/cache_write defaults")
    func decodesPricingSampleYAMLWithDerivedCacheDefaults() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        llm:
          pricing:
            gpt-4o:
              input: 2.5
              output: 10.0
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        let entry = try #require(appConfig.data.llm.pricing["gpt-4o"])
        #expect(entry.inputUSDPerMTok == 2.5)
        #expect(entry.outputUSDPerMTok == 10.0)
        #expect(entry.cacheReadUSDPerMTok == 0.25)
        #expect(entry.cacheWriteUSDPerMTok == 3.125)
    }

    @Test("decodes an llm.pricing entry with explicit cache_read/cache_write overrides")
    func decodesPricingSampleYAMLWithExplicitCacheOverrides() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        llm:
          pricing:
            gpt-4o:
              input: 2.5
              output: 10.0
              cache_read: 1.25
              cache_write: 2.5
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        let entry = try #require(appConfig.data.llm.pricing["gpt-4o"])
        #expect(entry.cacheReadUSDPerMTok == 1.25)
        #expect(entry.cacheWriteUSDPerMTok == 2.5)
    }

    @Test("update() writes and persists llm.pricing across a fresh AppConfig instance")
    func pricingPersistsAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.llm.pricing = ["gpt-4o": LLMModelPricing(inputUSDPerMTok: 2.5, outputUSDPerMTok: 10.0)]
        }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.llm.pricing["gpt-4o"]?.inputUSDPerMTok == 2.5)
        #expect(reloaded.data.llm.pricing["gpt-4o"]?.outputUSDPerMTok == 10.0)
    }

    @Test("saved YAML uses snake_case keys for llm.pricing entries")
    func savedYAMLUsesSnakeCaseForPricing() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.llm.pricing = ["gpt-4o": LLMModelPricing(inputUSDPerMTok: 2.5, outputUSDPerMTok: 10.0, cacheReadUSDPerMTok: 1.25, cacheWriteUSDPerMTok: 2.5)]
        }

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let pricing = (root?["llm"] as? [String: Any])?["pricing"] as? [String: Any]
        let entry = pricing?["gpt-4o"] as? [String: Any]
        #expect(entry?.keys.contains("input") == true)
        #expect(entry?.keys.contains("output") == true)
        #expect(entry?.keys.contains("cache_read") == true)
        #expect(entry?.keys.contains("cache_write") == true)
    }

    // MARK: - SttConfig defaults (`docs/design/11-streaming-stt.md` section 3.9)

    @Test("missing config.yaml starts with design section 3.9's documented stt defaults")
    func missingFileStartsWithSttDefaults() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt == .default)
        #expect(appConfig.data.stt.engine == "nemotron-streaming")
        #expect(appConfig.data.stt.language == "ja-JP")
        #expect(appConfig.data.stt.chunkMs == 2_240)
        #expect(appConfig.data.stt.segmentIdleTimeout == 2.0)
        #expect(appConfig.data.stt.maxSegmentCharacters == 120)
        #expect(appConfig.data.stt.twoPassDecode == true)
    }

    @Test("a config.yaml without an stt: key falls back to SttConfig.default (backward compatible)")
    func missingSttKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a missing stt: key must not fail the whole decode")
        #expect(appConfig.data.stt == .default)

        // The lenient decode must not leave save() permanently refused.
        appConfig.update { $0.stt.language = "en-US" }
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt.language == "en-US")
    }

    @Test("a partial stt: section (only chunk_ms) fills every other field from SttConfig.default")
    func partialSttSectionFillsMissingFieldsFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialYAML = """
        stt:
          chunk_ms: 1120
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a partial stt: section must not fail the whole config.yaml decode")
        #expect(appConfig.data.stt.chunkMs == 1_120, "the field the user did write must still be honored")
        #expect(appConfig.data.stt.engine == SttConfig.default.engine)
        #expect(appConfig.data.stt.language == SttConfig.default.language)
    }

    @Test("decodes design section 3.9's sample config.yaml stt section")
    func decodesDesignSampleSttYAML() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        stt:
          engine: nemotron-streaming
          language: ja-JP
          chunk_ms: 2240
          segment_idle_timeout: 2.0
          max_segment_characters: 120
          two_pass_decode: true
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt == .default)
    }

    @Test("stt.language passes through unvalidated")
    func languagePassesThroughUnvalidated() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        stt:
          language: auto
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt.language == "auto")
    }

    @Test("stt.language empty string falls back to SttConfig.default.language")
    func emptyLanguageFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        stt:
          language: ""
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt.language == SttConfig.default.language)
    }

    @Test("an unknown stt.engine value falls back to SttConfig.default.engine")
    func unknownEngineFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        stt:
          engine: sherpa-onnx
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt.engine == SttConfig.default.engine)
    }

    @Test(
        "every valid stt.chunk_ms tier passes through unchanged",
        arguments: [560, 1_120, 2_240, 4_480]
    )
    func validChunkMsTiersPassThrough(tier: Int) throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        stt:
          chunk_ms: \(tier)
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt.chunkMs == tier)
    }

    @Test("an invalid stt.chunk_ms is clamped to SttConfig.default.chunkMs with a warning")
    func invalidChunkMsIsClampedToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        stt:
          chunk_ms: 1000
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt.chunkMs == SttConfig.default.chunkMs)
    }

    @Test("a partial stt: section (only segment_idle_timeout/max_segment_characters) round-trips those fields")
    func partialSttSectionFillsSegmentThresholdsFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        stt:
          segment_idle_timeout: 3.5
          max_segment_characters: 200
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt.segmentIdleTimeout == 3.5)
        #expect(appConfig.data.stt.maxSegmentCharacters == 200)
        #expect(appConfig.data.stt.engine == SttConfig.default.engine)
        #expect(appConfig.data.stt.language == SttConfig.default.language)
        #expect(appConfig.data.stt.chunkMs == SttConfig.default.chunkMs)
    }

    @Test(
        "a non-positive stt.segment_idle_timeout is clamped to SttConfig.default.segmentIdleTimeout with a warning",
        arguments: [0.0, -1.0]
    )
    func invalidSegmentIdleTimeoutIsClampedToDefault(value: TimeInterval) throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        stt:
          segment_idle_timeout: \(value)
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt.segmentIdleTimeout == SttConfig.default.segmentIdleTimeout)
    }

    @Test(
        "a sub-1 stt.max_segment_characters is clamped to SttConfig.default.maxSegmentCharacters with a warning",
        arguments: [0, -5]
    )
    func invalidMaxSegmentCharactersIsClampedToDefault(value: Int) throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        stt:
          max_segment_characters: \(value)
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt.maxSegmentCharacters == SttConfig.default.maxSegmentCharacters)
    }

    // MARK: - SttConfig.twoPassDecode (`docs/design/33-meeting-two-pass-decode.md` §4/MT10)

    @Test("a stt: section without two_pass_decode falls back to true (backward compatible, MT10)")
    func missingTwoPassDecodeKeyFallsBackToTrue() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        stt:
          chunk_ms: 1120
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt.twoPassDecode == true)
    }

    @Test("stt.two_pass_decode: false decodes to false")
    func explicitFalseTwoPassDecodeDecodesToFalse() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        stt:
          two_pass_decode: false
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.stt.twoPassDecode == false)
    }

    // MARK: - SttConfig round-trip

    @Test("update() writes and persists stt settings across a fresh AppConfig instance")
    func sttSettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.stt = SttConfig(
                engine: "nemotron-streaming",
                language: "en-US",
                chunkMs: 4_480,
                segmentIdleTimeout: 3.5,
                maxSegmentCharacters: 200,
                twoPassDecode: false
            )
        }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(
            reloaded.data.stt == SttConfig(
                engine: "nemotron-streaming",
                language: "en-US",
                chunkMs: 4_480,
                segmentIdleTimeout: 3.5,
                maxSegmentCharacters: 200,
                twoPassDecode: false
            )
        )
    }

    @Test("saved YAML uses snake_case keys for stt")
    func savedYAMLUsesSnakeCaseForStt() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let stt = root?["stt"] as? [String: Any]
        #expect(stt?.keys.contains("engine") == true)
        #expect(stt?.keys.contains("language") == true)
        #expect(stt?.keys.contains("chunk_ms") == true)
        #expect(stt?.keys.contains("segment_idle_timeout") == true)
        #expect(stt?.keys.contains("max_segment_characters") == true)
        #expect(stt?.keys.contains("two_pass_decode") == true)
    }

    // MARK: - SummaryConfig defaults (`docs/design/04-summary-updater.md` §8)

    @Test("missing config.yaml starts with kikimi.md 12 章's documented summary defaults")
    func missingFileStartsWithSummaryDefaults() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.summary == .default)
        #expect(appConfig.data.summary.model == "claude-haiku-4-5-20251001")
        #expect(appConfig.data.summary.updateTriggerSegments == 20)
        #expect(appConfig.data.summary.updateTriggerSeconds == 180)
        #expect(appConfig.data.summary.autoNaming == true)
    }

    @Test("a config.yaml without a summary: key falls back to SummaryConfig.default (backward compatible)")
    func missingSummaryKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a missing summary: key must not fail the whole decode")
        #expect(appConfig.data.summary == .default)

        // The lenient decode must not leave save() permanently refused.
        appConfig.update { $0.summary.updateTriggerSegments = 30 }
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.summary.updateTriggerSegments == 30)
    }

    @Test("a partial summary: section (only update_trigger_segments) fills every other field from SummaryConfig.default")
    func partialSummarySectionFillsMissingFieldsFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialYAML = """
        summary:
          update_trigger_segments: 30
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a partial summary: section must not fail the whole config.yaml decode")
        #expect(appConfig.data.summary.updateTriggerSegments == 30, "the field the user did write must still be honored")
        #expect(appConfig.data.summary.model == SummaryConfig.default.model)
        #expect(appConfig.data.summary.updateTriggerSeconds == SummaryConfig.default.updateTriggerSeconds)
        #expect(appConfig.data.summary.autoNaming == SummaryConfig.default.autoNaming)
    }

    @Test("decodes kikimi.md 12 章's sample config.yaml summary section")
    func decodesDesignSampleSummaryYAML() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        summary:
          model: claude-haiku-4-5-20251001
          update_trigger_segments: 20
          update_trigger_seconds: 180
          auto_naming: true
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.summary == .default)
    }

    @Test("summary.update_trigger_segments < 1 is clamped to SummaryConfig.default.updateTriggerSegments with a warning")
    func invalidUpdateTriggerSegmentsIsClampedToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let invalidYAML = """
        summary:
          update_trigger_segments: 0
        """
        try invalidYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.summary.updateTriggerSegments == SummaryConfig.default.updateTriggerSegments)
    }

    @Test("summary.update_trigger_seconds < 0 is clamped to SummaryConfig.default.updateTriggerSeconds with a warning")
    func invalidUpdateTriggerSecondsIsClampedToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let invalidYAML = """
        summary:
          update_trigger_seconds: -5
        """
        try invalidYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.summary.updateTriggerSeconds == SummaryConfig.default.updateTriggerSeconds)
    }

    // MARK: - SummaryConfig round-trip

    @Test("update() writes and persists summary settings across a fresh AppConfig instance")
    func summarySettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.summary = SummaryConfig(
                model: "claude-sonnet-4-5",
                updateTriggerSegments: 10,
                updateTriggerSeconds: 60,
                autoNaming: false
            )
        }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.summary == SummaryConfig(
            model: "claude-sonnet-4-5",
            updateTriggerSegments: 10,
            updateTriggerSeconds: 60,
            autoNaming: false
        ))
    }

    @Test("saved YAML uses snake_case keys for summary")
    func savedYAMLUsesSnakeCaseForSummary() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let summary = root?["summary"] as? [String: Any]
        #expect(summary?.keys.contains("update_trigger_segments") == true)
        #expect(summary?.keys.contains("update_trigger_seconds") == true)
        #expect(summary?.keys.contains("auto_naming") == true)
    }

    // MARK: - WatchersConfig defaults (`docs/design/05-watcher-runner.md` §11)

    @Test("missing config.yaml starts with the documented watchers defaults")
    func missingFileStartsWithWatchersDefaults() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.watchers == .default)
        #expect(appConfig.data.watchers.presetsDir == "~/.config/kikimi/watchers/")
        #expect(appConfig.data.watchers.defaultEnabledFile == "~/.config/kikimi/default_watchers.yaml")
        #expect(appConfig.data.watchers.defaultModel == "claude-haiku-4-5-20251001")
    }

    @Test("a config.yaml without a watchers: key falls back to WatchersConfig.default (backward compatible)")
    func missingWatchersKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a missing watchers: key must not fail the whole decode")
        #expect(appConfig.data.watchers == .default)
    }

    @Test("a partial watchers: section (only default_model) fills every other field from WatchersConfig.default")
    func partialWatchersSectionFillsMissingFieldsFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialYAML = """
        watchers:
          default_model: claude-sonnet-4-5
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a partial watchers: section must not fail the whole config.yaml decode")
        #expect(appConfig.data.watchers.defaultModel == "claude-sonnet-4-5")
        #expect(appConfig.data.watchers.presetsDir == WatchersConfig.default.presetsDir)
        #expect(appConfig.data.watchers.defaultEnabledFile == WatchersConfig.default.defaultEnabledFile)
    }

    @Test("update() writes and persists watchers settings across a fresh AppConfig instance")
    func watchersSettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.watchers = WatchersConfig(
                presetsDir: "~/custom/watchers/",
                defaultEnabledFile: "~/custom/default_watchers.yaml",
                defaultModel: "claude-sonnet-4-5"
            )
        }

        let reloaded = makeAppConfig(in: dir)
        #expect(reloaded.data.watchers == WatchersConfig(
            presetsDir: "~/custom/watchers/",
            defaultEnabledFile: "~/custom/default_watchers.yaml",
            defaultModel: "claude-sonnet-4-5"
        ))
    }

    @Test("saved YAML uses snake_case keys for watchers")
    func savedYAMLUsesSnakeCaseForWatchers() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let watchers = root?["watchers"] as? [String: Any]
        #expect(watchers?.keys.contains("presets_dir") == true)
        #expect(watchers?.keys.contains("default_enabled_file") == true)
        #expect(watchers?.keys.contains("default_model") == true)
    }

    // MARK: - ExportConfig defaults (`docs/design/08-wiki-export.md` §5)

    @Test("missing config.yaml starts with the documented export defaults")
    func missingFileStartsWithExportDefaults() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.export == .default)
        #expect(appConfig.data.export.enabled == true)
        #expect(appConfig.data.export.targetDir == "~/Documents/Kikimi/export/")
    }

    @Test("a config.yaml without an export: key falls back to ExportConfig.default (backward compatible)")
    func missingExportKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a missing export: key must not fail the whole decode")
        #expect(appConfig.data.export == .default)

        // The lenient decode must not leave save() permanently refused.
        appConfig.update { $0.export.enabled = false }
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.export.enabled == false)
    }

    @Test("a partial export: section (only enabled) fills every other field from ExportConfig.default")
    func partialExportSectionFillsMissingFieldsFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialYAML = """
        export:
          enabled: false
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a partial export: section must not fail the whole config.yaml decode")
        #expect(appConfig.data.export.enabled == false, "the field the user did write must still be honored")
        #expect(appConfig.data.export.targetDir == ExportConfig.default.targetDir)
    }

    @Test("decodes kikimi.md 12 章's sample config.yaml export section")
    func decodesDesignSampleExportYAML() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        export:
          enabled: true
          target_dir: ~/Documents/Kikimi/export/
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.export == .default)
    }

    @Test("update() writes and persists export settings across a fresh AppConfig instance")
    func exportSettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.export = ExportConfig(enabled: false, targetDir: "~/custom/wiki/_raw/kikimi/")
        }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.export == ExportConfig(enabled: false, targetDir: "~/custom/wiki/_raw/kikimi/"))
    }

    @Test("saved YAML uses snake_case keys for export")
    func savedYAMLUsesSnakeCaseForExport() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let export = root?["export"] as? [String: Any]
        #expect(export?.keys.contains("enabled") == true)
        #expect(export?.keys.contains("target_dir") == true)
    }

    // MARK: - DictationConfig defaults (`docs/design/25-dictation-mode.md` R10/§9)

    @Test("missing config.yaml starts with the documented dictation defaults (disabled, pasteboard)")
    func missingFileStartsWithDictationDefaults() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.dictation == .default)
        #expect(appConfig.data.dictation.enabled == false)
        #expect(appConfig.data.dictation.insertMethod == .pasteboard)
        #expect(appConfig.data.dictation.micDeviceUID == "")
        #expect(appConfig.data.dictation.language == "")
        #expect(appConfig.data.dictation.refine == false)
        #expect(appConfig.data.dictation.model == "")
        #expect(appConfig.data.dictation.refineTimeoutMs == 3_000)
        #expect(appConfig.data.dictation.context == .default)
        #expect(
            appConfig.data.dictation.context.global == nil,
            "docs/design/42-prompt-overrides.md §7.2: an absent key decodes to nil, not the (now-nil) DictationContextConfig.default.global"
        )
        #expect(appConfig.data.dictation.context.apps == [])
    }

    @Test("a config.yaml without a dictation: key falls back to DictationConfig.default (backward compatible)")
    func missingDictationKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        diarization:
          enabled: true
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a missing dictation: key must not fail the whole decode")
        #expect(appConfig.data.dictation == .default)
    }

    @Test("a partial dictation: section (only enabled) fills every other field from DictationConfig.default")
    func partialDictationSectionFillsMissingFieldsFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialYAML = """
        dictation:
          enabled: true
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a partial dictation: section must not fail the whole config.yaml decode")
        #expect(appConfig.data.dictation.enabled == true, "the field the user did write must still be honored")
        #expect(appConfig.data.dictation.insertMethod == DictationConfig.default.insertMethod)
        #expect(appConfig.data.dictation.micDeviceUID == DictationConfig.default.micDeviceUID)
        #expect(appConfig.data.dictation.refineTimeoutMs == DictationConfig.default.refineTimeoutMs)
        #expect(appConfig.data.dictation.context == DictationConfig.default.context)
    }

    @Test("decodes design section 9's sample config.yaml dictation section")
    func decodesDesignSampleDictationYAML() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        dictation:
          enabled: false
          insert_method: pasteboard
          mic_device_uid: ""
          language: ""
          refine: false
          model: ""
          refine_timeout_ms: 3000
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.dictation == .default)
    }

    @Test("dictation.insert_method: unicode decodes to .unicode")
    func insertMethodUnicodeDecodes() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        dictation:
          insert_method: unicode
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.dictation.insertMethod == .unicode)
    }

    @Test("an unknown dictation.insert_method value falls back to .pasteboard")
    func unknownInsertMethodFallsBackToPasteboard() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        dictation:
          insert_method: auto
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.dictation.insertMethod == .pasteboard)
    }

    @Test("a negative dictation.refine_timeout_ms is clamped to DictationConfig.default.refineTimeoutMs with a warning")
    func negativeRefineTimeoutMsIsClampedToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        dictation:
          refine_timeout_ms: -1
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.dictation.refineTimeoutMs == DictationConfig.default.refineTimeoutMs)
    }

    // MARK: - DictationContextConfig (`docs/design/25-dictation-mode.md` §14.2/§14.6, R12/R17)

    @Test("a dictation: section without a context: key decodes global as nil (§7.2: no default fallback)")
    func missingDictationContextKeyDecodesGlobalAsNil() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        dictation:
          enabled: true
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.dictation.context == .default)
        #expect(appConfig.data.dictation.context.global == nil)
        #expect(appConfig.data.dictation.context.apps == [])
    }

    @Test("a partial dictation.context section (only global) fills apps from DictationContextConfig.default")
    func partialDictationContextFillsAppsFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        dictation:
          context:
            global: "カスタムルール"
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.dictation.context.global == "カスタムルール")
        #expect(appConfig.data.dictation.context.apps == [])
    }

    @Test("dictation.context.global accepts an explicit empty string verbatim (no validation, R17's escape hatch), distinct from an absent key")
    func emptyGlobalContextIsAcceptedVerbatim() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        dictation:
          context:
            global: ""
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.dictation.context.global == "")
        #expect(appConfig.data.dictation.context.global != nil, "an explicit empty string must not collapse into the 'key absent' nil case")
    }

    @Test("a nil dictation.context.global round-trips as an omitted key, not a re-materialized default")
    func nilGlobalRoundTripsAsOmittedKey() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(appConfig.data.dictation.context.global == nil)
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let context = (root?["dictation"] as? [String: Any])?["context"] as? [String: Any]
        #expect(
            context?.keys.contains("global") != true,
            "docs/design/42-prompt-overrides.md §7.2: a nil global must not round-trip as a materialized default/empty-string key"
        )

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.dictation.context.global == nil)
    }

    @Test("a partial dictation.context section (only apps) decodes global as nil, not DictationContextConfig.default.global")
    func partialDictationContextFillsGlobalFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        dictation:
          context:
            apps:
              - bundle_id: com.tinyspeck.slackmacgap
                context: "絵文字は使わない"
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.dictation.context.global == nil)
        #expect(appConfig.data.dictation.context.apps == [
            DictationAppContext(bundleID: "com.tinyspeck.slackmacgap", context: "絵文字は使わない")
        ])
    }

    @Test("dictation.context.apps decodes a well-formed list of bundle_id/context pairs")
    func decodesWellFormedAppsList() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        dictation:
          context:
            apps:
              - bundle_id: com.tinyspeck.slackmacgap
                context: "絵文字は使わない"
              - bundle_id: com.apple.dt.Xcode
                context: "コード用語はそのまま残す"
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.dictation.context.apps == [
            DictationAppContext(bundleID: "com.tinyspeck.slackmacgap", context: "絵文字は使わない"),
            DictationAppContext(bundleID: "com.apple.dt.Xcode", context: "コード用語はそのまま残す")
        ])
    }

    @Test("one malformed entry in dictation.context.apps falls back to an empty list for the whole array")
    func malformedAppsEntryFallsBackToEmptyArray() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        dictation:
          context:
            global: "カスタムルール"
            apps:
              - bundle_id: com.tinyspeck.slackmacgap
                context: "絵文字は使わない"
              - context: "bundle_idが欠落"
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a malformed apps: entry must not fail the whole config.yaml decode")
        #expect(appConfig.data.dictation.context.apps == [], "the whole array falls back to empty, not just the bad entry")
        #expect(appConfig.data.dictation.context.global == "カスタムルール", "the sibling global field is unaffected")
    }

    // MARK: - Back-compat: a lingering dictation.context.glossary key (`docs/design/28-glossary.md` §2)
    //
    // The glossary used to live at `dictation.context.glossary` (§15/R19), but was promoted to a
    // top-level `glossary:` section once meeting-transcript refinement started using it too.
    // `DictationContextConfig` no longer has a `glossary` field at all, so an old `config.yaml` with
    // this key must still decode without error -- the key is simply unrecognized and ignored, not
    // migrated (the task's "後方互換性" requirement: no migration needed, just no crash).

    @Test("a lingering dictation.context.glossary key (from before the promotion to top-level) does not break config.yaml decode")
    func legacyDictationContextGlossaryKeyIsIgnoredWithoutError() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        dictation:
          context:
            global: "カスタムルール"
            glossary:
              - term: nekosuke
                reading: ねこすけ
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a legacy dictation.context.glossary key must not fail the whole config.yaml decode")
        #expect(appConfig.data.dictation.context.global == "カスタムルール", "the sibling global field is unaffected")
        #expect(appConfig.data.glossary == [], "the legacy key is ignored, not migrated to the new top-level section")
    }

    // MARK: - Top-level glossary (`docs/design/28-glossary.md` §2)

    @Test("missing glossary: key falls back to an empty list")
    func missingTopLevelGlossaryKeyFallsBackToEmptyList() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.glossary == [])
    }

    @Test("glossary: decodes a well-formed list of term/reading pairs")
    func decodesWellFormedTopLevelGlossaryList() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        glossary:
          - term: nekosuke
            reading: ねこすけ
          - term: Acme Works
            reading: ""
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.glossary == [
            GlossaryEntry(term: "nekosuke", reading: "ねこすけ"),
            GlossaryEntry(term: "Acme Works", reading: "")
        ])
    }

    @Test("one malformed entry in glossary: falls back to an empty list for the whole array")
    func malformedTopLevelGlossaryEntryFallsBackToEmptyArray() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        glossary:
          - term: nekosuke
            reading: ねこすけ
          - reading: "termが欠落"
        stt:
          language: en-US
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a malformed glossary: entry must not fail the whole config.yaml decode")
        #expect(appConfig.data.glossary == [], "the whole array falls back to empty, not just the bad entry")
        #expect(appConfig.data.stt.language == "en-US", "sibling sections are unaffected")
    }

    @Test("update() writes and persists the top-level glossary across a fresh AppConfig instance")
    func glossarySettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let glossary = [
            GlossaryEntry(term: "nekosuke", reading: "ねこすけ"),
            GlossaryEntry(term: "Acme Works", reading: "")
        ]

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { $0.glossary = glossary }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.glossary == glossary)
    }

    @Test("saved YAML places glossary at the top level, not nested under dictation.context")
    func savedYAMLPlacesGlossaryAtTopLevel() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { $0.glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")] }
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        #expect(root?.keys.contains("glossary") == true)
        let dictation = root?["dictation"] as? [String: Any]
        let context = dictation?["context"] as? [String: Any]
        #expect(context?.keys.contains("glossary") != true, "glossary must not be re-nested under dictation.context")
    }

    // MARK: - glossary_categories (`docs/design/28-glossary.md` §1.2)

    @Test("missing glossary_categories: key falls back to an empty list")
    func missingGlossaryCategoriesKeyFallsBackToEmptyList() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.glossaryCategories == [])
    }

    @Test("glossary_categories: decodes id/name/instruction, and an omitted instruction defaults to empty")
    func decodesWellFormedGlossaryCategoriesList() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        glossary_categories:
          - id: person
            name: 人物名
            instruction: |-
              以下は人物名です。
          - id: env
            name: 環境名
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.glossaryCategories == [
            GlossaryCategory(id: "person", name: "人物名", instruction: "以下は人物名です。"),
            GlossaryCategory(id: "env", name: "環境名", instruction: "")
        ])
    }

    @Test("one malformed glossary_categories entry falls back to an empty list for the whole array")
    func malformedGlossaryCategoryFallsBackToEmptyArray() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        glossary_categories:
          - id: person
            name: 人物名
          - name: idが欠落
        stt:
          language: en-US
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a malformed category must not fail the whole config.yaml decode")
        #expect(appConfig.data.glossaryCategories == [], "the whole array falls back to empty, not just the bad entry")
        #expect(appConfig.data.stt.language == "en-US", "sibling sections are unaffected")
    }

    /// Unlike a structurally malformed category, a duplicate id is repaired rather than fatal to the
    /// whole array -- discarding every category over one hand-edit typo would be disproportionate.
    @Test("duplicate glossary_categories ids keep only the first occurrence, in file order")
    func duplicateGlossaryCategoryIdsKeepTheFirstOccurrence() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        glossary_categories:
          - id: dup
            name: 先に書かれた方
          - id: dup
            name: 後に書かれた方
          - id: env
            name: 環境名
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.glossaryCategories == [
            GlossaryCategory(id: "dup", name: "先に書かれた方"),
            GlossaryCategory(id: "env", name: "環境名")
        ])
    }

    /// The category reference is preserved verbatim; resolving it to 未分類 is `GlossaryCategorization`'s
    /// job at the point of use, not the decoder's (one source of truth, see `GlossaryEntry.category`).
    @Test("an entry whose category names no existing category still decodes, keeping the id verbatim")
    func entryWithDanglingCategoryIdDecodesWithoutError() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        glossary:
          - term: nekosuke
            reading: ねこすけ
            category: 存在しないカテゴリ
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.glossary.first?.category == "存在しないカテゴリ")
    }

    @Test("an entry with no category: key decodes to nil (pre-categories config.yaml)")
    func entryWithoutCategoryKeyDecodesToNil() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        glossary:
          - term: nekosuke
            reading: ねこすけ
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.glossary == [GlossaryEntry(term: "nekosuke", reading: "ねこすけ", category: nil)])
    }

    @Test("update() writes and persists glossary_categories across a fresh AppConfig instance")
    func glossaryCategoriesPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let categories = [
            GlossaryCategory(id: "person", name: "人物名", instruction: "敬称は残す"),
            GlossaryCategory(id: "env", name: "環境名")
        ]

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { $0.glossaryCategories = categories }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.glossaryCategories == categories)
    }

    /// The invariant the whole id/name split exists for: a category stays renameable forever, and no
    /// entry has to be rewritten when it happens.
    @Test("renaming a category does not touch any entry that references it")
    func renamingACategoryDoesNotTouchAnyEntry() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.glossaryCategories = [GlossaryCategory(id: "c1", name: "人物名")]
            config.glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ", category: "c1")]
        }

        appConfig.update { $0.glossaryCategories[0].name = "人物名(改)" }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.glossaryCategories == [GlossaryCategory(id: "c1", name: "人物名(改)")])
        #expect(reloaded.data.glossary == [GlossaryEntry(term: "nekosuke", reading: "ねこすけ", category: "c1")])
    }

    @Test("saved YAML places glossary_categories at the top level under its snake_case key")
    func savedYAMLPlacesGlossaryCategoriesAtTopLevel() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { $0.glossaryCategories = [GlossaryCategory(id: "person", name: "人物名")] }
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        #expect(root?.keys.contains("glossary_categories") == true)
        #expect(root?.keys.contains("glossaryCategories") != true, "the key must be snake_case, not the Swift name")

        let categories = root?["glossary_categories"] as? [[String: Any]]
        #expect(categories?.first?["id"] as? String == "person")
        #expect(categories?.first?["name"] as? String == "人物名")
    }

    // MARK: - DictationConfig round-trip

    @Test("update() writes and persists dictation settings across a fresh AppConfig instance")
    func dictationSettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let context = DictationContextConfig(
            global: "カスタムルール",
            apps: [DictationAppContext(bundleID: "com.tinyspeck.slackmacgap", context: "絵文字は使わない")]
        )

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.dictation = DictationConfig(
                enabled: true,
                insertMethod: .unicode,
                micDeviceUID: "device-uid",
                language: "en-US",
                refine: true,
                model: "claude-sonnet-4-5",
                refineTimeoutMs: 5_000,
                context: context
            )
        }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.dictation == DictationConfig(
            enabled: true,
            insertMethod: .unicode,
            micDeviceUID: "device-uid",
            language: "en-US",
            refine: true,
            model: "claude-sonnet-4-5",
            refineTimeoutMs: 5_000,
            context: context
        ))
    }

    @Test("saved YAML uses snake_case keys for dictation")
    func savedYAMLUsesSnakeCaseForDictation() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.dictation.context.apps = [DictationAppContext(bundleID: "com.example.app", context: "test")]
        }
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let dictation = root?["dictation"] as? [String: Any]
        #expect(dictation?.keys.contains("insert_method") == true)
        #expect(dictation?.keys.contains("mic_device_uid") == true)
        #expect(dictation?.keys.contains("refine_timeout_ms") == true)

        let context = dictation?["context"] as? [String: Any]
        #expect(context?.keys.contains("global") == true)
        #expect(context?.keys.contains("apps") == true)
        let apps = context?["apps"] as? [[String: Any]]
        #expect(apps?.first?.keys.contains("bundle_id") == true)
    }

    // MARK: - DefaultsConfig defaults (`docs/design/26-settings-ui.md` §4.2)

    @Test("missing config.yaml starts with kikimi.md 12 章's documented defaults section")
    func missingFileStartsWithDefaultsSectionDefaults() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.defaults == .default)
        #expect(appConfig.data.defaults.contextFile == "~/.config/kikimi/context/common.md")
        #expect(appConfig.data.defaults.summaryTemplateFile == "~/.config/kikimi/templates/summary.md")
    }

    @Test("a config.yaml without a defaults: key falls back to DefaultsConfig.default (backward compatible)")
    func missingDefaultsKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a missing defaults: key must not fail the whole decode")
        #expect(appConfig.data.defaults == .default)
    }

    @Test("a partial defaults: section (only context_file) fills the other field from DefaultsConfig.default")
    func partialDefaultsSectionFillsMissingFieldsFromDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let partialYAML = """
        defaults:
          context_file: ~/custom/context.md
        """
        try partialYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a partial defaults: section must not fail the whole config.yaml decode")
        #expect(appConfig.data.defaults.contextFile == "~/custom/context.md", "the field the user did write must still be honored")
        #expect(appConfig.data.defaults.summaryTemplateFile == DefaultsConfig.default.summaryTemplateFile)
    }

    @Test("update() writes and persists defaults settings across a fresh AppConfig instance")
    func defaultsSettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.defaults = DefaultsConfig(contextFile: "~/custom/context.md", summaryTemplateFile: "~/custom/summary.md")
        }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.defaults == DefaultsConfig(contextFile: "~/custom/context.md", summaryTemplateFile: "~/custom/summary.md"))
    }

    @Test("saved YAML uses snake_case keys for defaults")
    func savedYAMLUsesSnakeCaseForDefaults() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let defaultsSection = root?["defaults"] as? [String: Any]
        #expect(defaultsSection?.keys.contains("context_file") == true)
        #expect(defaultsSection?.keys.contains("summary_template_file") == true)
    }

    // MARK: - ProfilesConfig defaults (`docs/design/41-meeting-profiles.md` §2.4)

    @Test("missing config.yaml starts with design 41 §2.4's documented profiles section default")
    func missingFileStartsWithProfilesSectionDefault() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.profiles == .default)
        #expect(appConfig.data.profiles.dir == "~/.config/kikimi/profiles/")
    }

    @Test("a config.yaml without a profiles: key falls back to ProfilesConfig.default (backward compatible)")
    func missingProfilesKeyFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a missing profiles: key must not fail the whole decode")
        #expect(appConfig.data.profiles == .default)
    }

    @Test("a profiles: section without dir falls back to ProfilesConfig.default's dir")
    func profilesSectionWithoutDirFallsBackToDefault() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "profiles: {}".write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir)
        #expect(!appConfig.loadFailed, "a partial profiles: section must not fail the whole config.yaml decode")
        #expect(appConfig.data.profiles.dir == ProfilesConfig.default.dir)
    }

    @Test("update() writes and persists a custom profiles.dir across a fresh AppConfig instance")
    func profilesSettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.update { config in
            config.profiles = ProfilesConfig(dir: "~/custom/profiles/")
        }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.profiles == ProfilesConfig(dir: "~/custom/profiles/"))
    }

    @Test("saved YAML uses snake_case keys for profiles")
    func savedYAMLUsesSnakeCaseForProfiles() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appConfig = makeAppConfig(in: dir)
        appConfig.save()

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let profilesSection = root?["profiles"] as? [String: Any]
        #expect(profilesSection?.keys.contains("dir") == true)
    }

    // MARK: - API key Keychain migration (`docs/design/26-settings-ui.md` §3.1)

    @Test("a config.yaml with a plaintext llm.openai.api_key migrates it to the credential store on load, leaving config.yaml's field empty")
    func plaintextAPIKeyMigratesToCredentialStoreOnLoad() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        llm:
          openai:
            api_key: sk-plaintext
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let credentialStore = InMemoryCredentialStore()
        let appConfig = makeAppConfig(in: dir, credentialStore: credentialStore)

        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.llm.openai.apiKey == "", "the plaintext must be cleared from in-memory data once migrated")
        #expect(credentialStore.read(account: CredentialAccount.openAIAPIKey) == "sk-plaintext")

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let openai = (root?["llm"] as? [String: Any])?["openai"] as? [String: Any]
        #expect((openai?["api_key"] as? String) == "", "config.yaml must be rewritten with an empty api_key, not left holding the plaintext")
    }

    @Test("a config.yaml with an already-empty llm.openai.api_key does not write anything to the credential store (no-op)")
    func emptyAPIKeyDoesNotWriteToCredentialStore() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let credentialStore = InMemoryCredentialStore()
        let appConfig = makeAppConfig(in: dir, credentialStore: credentialStore)

        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.llm.openai.apiKey == "")
        #expect(credentialStore.read(account: CredentialAccount.openAIAPIKey) == nil)
    }

    @Test("a credential store write failure during migration leaves config.yaml's api_key value in place")
    func migrationFailureLeavesPlaintextInPlace() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        llm:
          openai:
            api_key: sk-plaintext
        """
        try yaml.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appConfig = makeAppConfig(in: dir, credentialStore: AlwaysFailingCredentialStore())

        #expect(!appConfig.loadFailed, "a migration write failure must not fail the whole config.yaml load")
        #expect(appConfig.data.llm.openai.apiKey == "sk-plaintext", "the plaintext must stay in place when the Keychain write fails")
    }

    /// Reloading a hand-edited config.yaml that re-adds a plaintext key after a previous successful
    /// migration must migrate it again (`docs/design/26-settings-ui.md` §3.1: "plaintext-on-disk is
    /// the state we always want to close as soon as it's observed").
    @Test("load() re-migrates a plaintext api_key that reappears in config.yaml after a prior successful migration")
    func reloadingReMigratesReAddedPlaintextAPIKey() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let credentialStore = InMemoryCredentialStore()

        let firstYAML = """
        llm:
          openai:
            api_key: sk-first
        """
        try firstYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        // Initial `init` -> `load()` migrates "sk-first" immediately.
        let appConfig = makeAppConfig(in: dir, credentialStore: credentialStore)
        #expect(appConfig.data.llm.openai.apiKey == "")
        #expect(credentialStore.read(account: CredentialAccount.openAIAPIKey) == "sk-first")

        // Simulate a user hand-editing config.yaml back in a new plaintext key, then AppConfig
        // picking it up via `load()` (as `FileWatcher`'s debounced reload would).
        let handEditedYAML = """
        llm:
          openai:
            api_key: sk-hand-edited
        """
        try handEditedYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)
        appConfig.load()

        #expect(!appConfig.loadFailed)
        #expect(appConfig.data.llm.openai.apiKey == "")
        #expect(credentialStore.read(account: CredentialAccount.openAIAPIKey) == "sk-hand-edited")
    }
}

/// Test double for the `migrateAPIKeyToKeychainIfNeeded()` failure path (`docs/design/26-settings-ui.md`
/// §3.1's "Keychain 書き込み失敗時は config.yaml の値がそのまま残る" scenario).
private struct AlwaysFailingCredentialStore: CredentialStoring {
    func read(account: String) -> String? { nil }
    func write(_ value: String, account: String) throws { throw CredentialStoreError.unhandledStatus(-1) }
    func delete(account: String) throws { throw CredentialStoreError.unhandledStatus(-1) }
}
